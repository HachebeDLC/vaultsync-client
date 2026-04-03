import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/system_path_service.dart';

final switchProfileResolverProvider = Provider<SwitchProfileResolver>((ref) {
  return SwitchProfileResolver(ref.watch(systemPathServiceProvider));
});

/// Handles Nintendo Switch / Eden profile ID probing and scan fixup.
/// Ensures that stale or byte-reversed profile folder entries are removed and
/// the authoritative profile ID from profiles.dat is injected into the scan list.
class SwitchProfileResolver {
  final SystemPathService _pathService;
  static final _profileRegex = RegExp(r'^[0-9A-Fa-f]{32}$');

  SwitchProfileResolver(this._pathService);

  Future<List<dynamic>> applyProfileFixes(
      List<dynamic> result, String effectivePath) async {
    final probed = await _pathService.probeProfileId(effectivePath);

    if (probed != null) {
      // Remove entries containing a different 32-char profile ID under the
      // save path — those are stale/wrong folders from a previous bad sync.
      result = result.where((f) {
        final path = (f['relPath'] as String?) ?? '';
        if (!path.contains('nand/user/save/0000000000000000/')) return true;
        final segments = path.split('/');
        final zeroIdx = segments.indexOf('0000000000000000');
        if (zeroIdx != -1 && zeroIdx + 1 < segments.length) {
          final candidate = segments[zeroIdx + 1];
          if (_profileRegex.hasMatch(candidate) && candidate != probed) {
            return false;
          }
        }
        return true;
      }).toList();

      // Inject the correct profile ID entry if not already present.
      final hasCorrectId = result.any((f) =>
          ((f['relPath'] as String?) ?? '')
              .contains('nand/user/save/0000000000000000/$probed'));
      if (!hasCorrectId) {
        result = List.from(result)
          ..add({
            'relPath': 'nand/user/save/0000000000000000/$probed',
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
