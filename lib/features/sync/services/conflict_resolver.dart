import 'package:shared_preferences/shared_preferences.dart';
import '../services/sync_path_resolver.dart';

class ConflictResolver {
  final SyncPathResolver _pathResolver;

  ConflictResolver(this._pathResolver);

  bool isJournaledSynced(SharedPreferences prefs, String systemId, String relPath, String remoteHash) {
    final key = 'journal_${systemId}_$relPath';
    return prefs.getString(key) == remoteHash;
  }

  Map<String, Map<String, dynamic>> processLocalFiles(String systemId, List<dynamic> localList) {
    final Map<String, Map<String, dynamic>> localFiles = {};
    final bool isPkgRoot = localList.any((f) => f['relPath'] == 'files' || f['relPath'].startsWith('files/'));

    for (var f in localList) {
      if (f['isDirectory'] == true) continue;
      final String originalRelPath = f['relPath'];

      if (isPkgRoot && !originalRelPath.contains('/')) {
        final ext = originalRelPath.split('.').last.toLowerCase();
        if (['ps2', 'srm', 'sav', 'save', 'state'].contains(ext)) continue;
      }
      final String cloudRelPath = _pathResolver.getCloudRelPath(systemId, originalRelPath);
      if (cloudRelPath.isEmpty || cloudRelPath.endsWith('/')) continue;
      
      final existing = localFiles[cloudRelPath];
      if (existing == null || (f['lastModified'] as num) > (existing['lastModified'] as num)) {
        f['originalRelPath'] = originalRelPath;
        localFiles[cloudRelPath] = f;
      }
    }
    return localFiles;
  }

  List<Map<String, dynamic>> sortResults(List<Map<String, dynamic>> results) {
    results.sort((a, b) => (a['relPath'] as String).compareTo(b['relPath'] as String));
    return results;
  }
}
