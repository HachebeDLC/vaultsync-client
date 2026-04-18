import 'dart:developer' as developer;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/system_path_service.dart';

final switchProfileResolverProvider = Provider<SwitchProfileResolver>((ref) {
  return SwitchProfileResolver(ref.watch(systemPathServiceProvider));
});

/// Handles Nintendo Switch / Eden profile ID probing and scan fixup.
///
/// Ensures that stale or byte-reversed profile folder entries are removed and
/// the authoritative profile ID from profiles.dat is injected into the scan
/// list. Aware of "device save" titles that bypass user profiles on real
/// hardware (and therefore on Eden) — those are whitelisted through the filter
/// even though they don't sit under the probed profile path.
class SwitchProfileResolver {
  final SystemPathService _pathService;

  /// Matches Switch title IDs: 16 hex chars starting with "01".
  /// Mirrors Argosy's `SwitchSaveHandler.isValidTitleId`.
  static final _titleIdRegex = RegExp(r'^01[0-9A-Fa-f]{14}$');

  /// Matches Switch profile folder IDs: 16 or 32 hex chars.
  static final _profileRegex = RegExp(r'^[0-9A-Fa-f]{32}$');

  static const _zeroUser = '0000000000000000';
  static const _zeroProfile = '00000000000000000000000000000000';

  /// Titles that store saves under `<zeroUser>/<zeroProfile>/<titleId>`
  /// rather than under the active user profile. Copied from Argosy's
  /// `DEVICE_SAVE_TITLE_IDS` — these are hardcoded in Horizon OS.
  static const deviceSaveTitleIds = <String>{
    '01006F8002326000', // Animal Crossing: New Horizons
    '0100D2F00D5C0000', // Nintendo Switch Sports
    '01000320000CC000', // 1-2-Switch
    '01002FF008C24000', // Ring Fit Adventure
    '0100C4B0034B2000', // Nintendo Labo Toy-Con 01: Variety Kit
    '01009AB0034E0000', // Nintendo Labo Toy-Con 02: Robot Kit
    '01001E9003502000', // Nintendo Labo Toy-Con 03: Vehicle Kit
    '0100165003504000', // Nintendo Labo Toy-Con 04: VR Kit
    '0100C1800A9B6000', // Go Vacation
  };

  SwitchProfileResolver(this._pathService);

  static bool isValidTitleId(String candidate) =>
      _titleIdRegex.hasMatch(candidate);

  static bool isDeviceSave(String titleId) =>
      deviceSaveTitleIds.contains(titleId.toUpperCase());

  Future<List<dynamic>> applyProfileFixes(
      List<dynamic> result, String effectivePath) async {
    final probed = await _pathService.probeProfileId(effectivePath);

    if (probed != null) {
      final requiredPrefix = 'nand/user/save/$_zeroUser/$probed';
      final deviceSavePrefix = 'nand/user/save/$_zeroUser/$_zeroProfile';

      result = result.where((f) {
        final path = (f['relPath'] as String?) ?? '';
        final segments = path.split('/');

        // Find the title ID anywhere in the path.
        final titleId =
            segments.firstWhere(isValidTitleId, orElse: () => '').toUpperCase();

        if (titleId.isNotEmpty && path.contains('nand/user/save')) {
          // Device saves legitimately live outside the user profile — keep
          // them if they're under `<zeroUser>/<zeroProfile>/<titleId>`, reject
          // otherwise.
          if (isDeviceSave(titleId)) {
            return path.contains(deviceSavePrefix);
          }
          // Non-device saves must be under the probed active profile.
          if (!path.contains(requiredPrefix)) {
            developer.log(
              'FILTER: rejecting Switch file in wrong profile location: $path',
              name: 'VaultSync',
              level: 800,
            );
            return false;
          }
        }

        // Strip stray 32-hex profile folders under `<zeroUser>/` that aren't
        // the probed profile (byte-reversed/stale leftovers).
        if (path.contains('nand/user/save/$_zeroUser/')) {
          final zeroIdx = segments.indexOf(_zeroUser);
          if (zeroIdx != -1 && zeroIdx + 1 < segments.length) {
            final candidate = segments[zeroIdx + 1];
            if (_profileRegex.hasMatch(candidate) &&
                candidate != probed &&
                candidate != _zeroProfile) {
              return false;
            }
          }
        }
        return true;
      }).toList();

      // Inject the correct profile ID entry if the scanner missed it.
      final hasCorrectId = result.any((f) =>
          ((f['relPath'] as String?) ?? '').contains(requiredPrefix));
      if (!hasCorrectId) {
        result = List.from(result)
          ..add({
            'relPath': requiredPrefix,
            'name': probed,
            'isDirectory': true,
            'uri': '',
            'size': 0,
            'lastModified': 0,
          });
      }
    }

    return result;
  }
}
