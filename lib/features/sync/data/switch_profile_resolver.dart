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
      final String requiredPrefix = 'nand/user/save/0000000000000000/$probed';
      
      // Filter out ANY Switch file that is not in the correct profile directory
      result = result.where((f) {
        final path = (f['relPath'] as String?) ?? '';
        final segments = path.split('/');
        
        // Find if this path contains a Title ID anywhere
        final titleIdx = segments.indexWhere((s) => RegExp(r'^0100[0-9A-Fa-f]{12}$').hasMatch(s));
        
        if (titleIdx != -1) {
          // If the relative path contains 'nand/user/save', it MUST be preceded by the correct profile path.
          // (If it doesn't contain it, it means the scanner anchored deep inside the profile already, which is fine).
          if (path.contains('nand/user/save') && !path.contains(requiredPrefix)) {
            print('📂 FILTER: Rejecting Switch file in wrong location: $path');
            return false;
          }
        }
        
        // Also remove other 32-char folders under the save root just in case
        if (path.contains('nand/user/save/0000000000000000/')) {
          final zeroIdx = segments.indexOf('0000000000000000');
          if (zeroIdx != -1 && zeroIdx + 1 < segments.length) {
            final candidate = segments[zeroIdx + 1];
            if (_profileRegex.hasMatch(candidate) && candidate != probed) {
              return false;
            }
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
