import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'sync_state_database.dart';
import '../services/conflict_resolver.dart';
import '../services/sync_path_resolver.dart';
import '../domain/notification_provider.dart';
import '../../../core/services/api_client.dart';
import '../../../core/services/api_client_provider.dart';

// Providers are wired in sync_repository.dart to avoid circular imports.
// Use syncDiffServiceProvider defined there.

/// Computes the diff between local and remote file state for a given system.
/// Also owns the paginated remote file fetch logic.
class SyncDiffService {
  final ApiClient _apiClient;
  final ConflictResolver _conflictResolver;
  final SyncStateDatabase _syncStateDb;
  final SyncPathResolver _pathResolver;
  final Ref? _ref;

  SyncDiffService(this._apiClient, this._conflictResolver, this._syncStateDb,
      this._pathResolver, [this._ref]);

  Future<List<dynamic>> fetchAllRemoteFiles(String prefix) async {
    final List<dynamic> all = [];
    String? cursor;
    do {
      final params = <String, String>{'prefix': prefix, 'limit': '20'};
      if (cursor != null) params['after'] = cursor;
      final response =
          await _apiClient.get('/api/v1/files', queryParams: params);
      final page = response['files'] as List<dynamic>? ?? [];
      all.addAll(page);
      cursor = response['next_cursor'] as String?;
    } while (cursor != null);
    return all;
  }

  Future<List<Map<String, dynamic>>> diffSystem(
    String systemId,
    String localPath, {
    required String effectivePath,
    required Future<List<dynamic>> Function(String, String, List<String>?)
        getCachedOrNewScan,
    required bool Function(SharedPreferences, String, String, String)
        isJournaledSynced,
    required void Function(SharedPreferences, String, String, String)
        recordSyncSuccess,
    List<String>? ignoredFolders,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final sid = systemId.toLowerCase();
      final isSwitch = sid == 'eden' || sid == 'switch';
      final cloudPrefix = isSwitch
          ? 'switch'
          : (localPath.toLowerCase().contains('retroarch')
              ? 'RetroArch'
              : systemId);

      final allRemoteFiles = await fetchAllRemoteFiles(cloudPrefix);

      final remoteFilesList = allRemoteFiles.where((f) {
        final path = f['path'] as String;
        final rel =
            path.contains('/') ? path.split('/').skip(1).join('/') : path;
        final firstSegment = rel.split('/').first.toLowerCase();
        if (isSwitch) {
          final isTitleId =
              RegExp(r'^[0-9A-Fa-f]{16}$').hasMatch(firstSegment);
          final isSystemPath = ['nand', 'config', 'files', 'gpu_drivers']
              .contains(firstSegment);
          return isTitleId && !isSystemPath;
        }
        if (sid == '3ds' || sid == 'azahar') return rel.startsWith('saves/');
        return true;
      }).toList();

      final remoteFiles = {for (var f in remoteFilesList) f['path']: f};
      final localList =
          await getCachedOrNewScan(systemId, effectivePath, ignoredFolders);
      final localFiles =
          _conflictResolver.processLocalFiles(systemId, localList);

      final cloudRelPaths = <String>{
        ...localFiles.keys,
        ...remoteFiles.keys
            .map((p) => p.substring(cloudPrefix.length + 1))
      };
      final results = <Map<String, dynamic>>[];

      for (final relPath in cloudRelPaths) {
        if (relPath.isEmpty) continue;
        final remotePath = '$cloudPrefix/$relPath';
        final localInfo = localFiles[relPath];
        final remoteInfo = remoteFiles[remotePath];
        String status = 'Synced';
        final type = (relPath.toLowerCase().contains('.state') ||
                relPath.toLowerCase().endsWith('.png'))
            ? 'State'
            : 'Save';

        if (localInfo == null) {
          status = 'Remote Only';
        } else if (remoteInfo == null) {
          status = 'Local Only';
        } else {
          final String remoteHash = remoteInfo['hash'];
          if (isJournaledSynced(prefs, systemId, relPath, remoteHash)) {
            status = 'Synced';
          } else {
            final cached = await _syncStateDb.getState(localInfo['uri']);
            final int localTs = (localInfo['lastModified'] as num).toInt();
            final int localSize = (localInfo['size'] as num).toInt();

            if (cached != null && cached['status'] == 'synced' && cached['hash'] == remoteHash) {
              // If the DB knows it's synced and the hashes match, trust it even if timestamps drifted slightly
              status = 'Synced';
              recordSyncSuccess(prefs, systemId, relPath, remoteHash);
            } else if (cached != null &&
                cached['size'] == localSize &&
                (cached['last_modified'] ~/ 1000) == (localTs ~/ 1000) &&
                cached['hash'] == remoteHash) {
              status = 'Synced';
              recordSyncSuccess(prefs, systemId, relPath, remoteHash);
            } else {
              final int remoteTs =
                  (remoteInfo['updated_at'] as num).toInt() ~/ 1000;
              if (localInfo['size'] != remoteInfo['size'] ||
                  (localTs ~/ 1000) != remoteTs) {
                status = 'Modified';
              }
            }
          }
        }

        results.add({
          'relPath': relPath,
          'remotePath': remotePath,
          'status': status,
          'type': type,
          'localInfo': localInfo,
          'remoteInfo': remoteInfo,
          'isDirectory': false,
          'name': relPath.split('/').last,
        });
      }

      return _conflictResolver.sortResults(results);
    } catch (e) {
      _ref?.read(notificationLogProvider.notifier).addError(e, systemId: systemId);
      rethrow;
    }
  }
}
