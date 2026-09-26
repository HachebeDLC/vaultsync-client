import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'sync_state_database.dart';
import '../services/conflict_resolver.dart';
import '../services/sync_path_resolver.dart';
import '../domain/notification_provider.dart';
import '../../../core/services/api_client.dart';

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

  /// Keeps only the rows that really live under [prefix] as a path segment.
  ///
  /// The server matches `path ILIKE '<prefix>%'` with no delimiter, so asking
  /// for `wii` also returns the whole `wiiu/` namespace. That is not a
  /// hypothetical clash: a Cemu backup stored under `wiiu/00050000/…` was
  /// handed to the Wii system, which mapped it to `title/wiiu/…` inside
  /// Dolphin's folder and then failed the download — the size checked against
  /// the row it asked for did not match the bytes of the row it received
  /// ("expected 1027208 bytes, got 1027325").
  ///
  /// Filtering here rather than only server-side keeps the client correct
  /// against servers that have not been updated yet.
  @visibleForTesting
  static List<dynamic> filterToPrefix(List<dynamic> rows, String prefix) {
    final base = prefix.endsWith('/')
        ? prefix.substring(0, prefix.length - 1)
        : prefix;
    if (base.isEmpty) return rows;
    final lower = '${base.toLowerCase()}/';
    return rows.where((r) {
      final path = (r is Map ? r['path'] : null) as String?;
      if (path == null) return false;
      final p = path.toLowerCase();
      return p.startsWith(lower) || p == base.toLowerCase();
    }).toList();
  }

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

    final kept = filterToPrefix(all, prefix);
    if (kept.length != all.length) {
      developer.log(
          'DIFF: Dropped ${all.length - kept.length} rows outside the "$prefix/" namespace '
          '(server prefix match has no delimiter)',
          name: 'VaultSync',
          level: 900);
    }
    return kept;
  }

  Future<List<Map<String, dynamic>>> diffSystem(
    String systemId,
    String localPath, {
    required String effectivePath,
    required Future<List<dynamic>> Function(String, String, List<String>?, [List<String>?])
        getCachedOrNewScan,
    required bool Function(SharedPreferences, String, String, String, {int? localTs})
        isJournaledSynced,
    required void Function(SharedPreferences, String, String, String, [int?])
        recordSyncSuccess,
    List<String>? ignoredFolders,
    List<String>? saveExtensions,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final sid = systemId.toLowerCase();
      final isSwitch = sid == 'eden' || sid == 'switch';
      final isRetroArch = sid.contains('retroarch') || localPath.toLowerCase().contains('retroarch');
      final cloudPrefix = isSwitch
          ? 'switch'
          : (isRetroArch
              ? 'RetroArch'
              : (sid == 'gc' || sid == 'dolphin' ? 'GC' : systemId));
      final actualPrefix = cloudPrefix.toLowerCase();

      List<dynamic> allRemoteFiles = [];
      try {
        allRemoteFiles = await fetchAllRemoteFiles(cloudPrefix);
      } catch (e) {
        // If we fail to fetch remote files, log it but proceed with empty remote files
        // so that local files can still be viewed and queued for upload.
      }
      final remoteFilesList = allRemoteFiles.where((f) {
        final path = f['path'] as String;
        if (isSwitch) {
          final rel = path.startsWith('switch/') ? path.substring(7) : path;
          final parts = rel.split('/');
          if (parts.isEmpty) return false;
          final titleIdSegment = parts.first;
          final isTitleId = RegExp(r'^[0-9A-Fa-f]{16}$').hasMatch(titleIdSegment);
          final isSystemPath = ['nand', 'config', 'files', 'gpu_drivers'].contains(titleIdSegment);
          return isTitleId && !isSystemPath;
        }
        // For other systems, we trust the server's prefix filter was sufficient
        // but we filter out obviously wrong things if necessary.
        return true;
      }).toList();

      final remoteFiles = <String, dynamic>{};
      for (var f in remoteFilesList) {
        final path = f['path'] as String;
        // Strip prefix if it exists (case-insensitive)
        String rel = path;
        if (path.toLowerCase().startsWith('$actualPrefix/')) {
          rel = path.substring(actualPrefix.length + 1);
        } else {
          // Check if it starts with systemId (in case it differs from cloudPrefix)
          final sidPrefix = '${systemId.toLowerCase()}/';
          if (path.toLowerCase().startsWith(sidPrefix)) {
            rel = path.substring(sidPrefix.length);
          }
        }
        remoteFiles[rel] = f;
      }
      final localList =
          await getCachedOrNewScan(systemId, effectivePath, ignoredFolders, saveExtensions);
      final localFiles =
          _conflictResolver.processLocalFiles(systemId, localList);

      // Wii/GC/Dolphin NAND blobs are quarantined as garbage server-side and
      // must never show up as syncable in the dashboard/diff view either —
      // see SyncPathResolver.isWiiNandBlobCloudPath (mirrors
      // cleanup_garbage._is_wii_nand_blob) and SyncRepository.syncSystem's
      // matching filter on the actual upload/download path.
      localFiles.removeWhere((relPath, _) =>
          SyncPathResolver.isWiiNandBlobCloudPath('$cloudPrefix/$relPath'));
      remoteFiles.removeWhere((relPath, info) {
        final fullPath = (info is Map && info['path'] is String)
            ? info['path'] as String
            : '$cloudPrefix/$relPath';
        return SyncPathResolver.isWiiNandBlobCloudPath(fullPath);
      });

      final cloudRelPaths = <String>{
        ...localFiles.keys,
        ...remoteFiles.keys
      };
      final results = <Map<String, dynamic>>[];

      for (final relPath in cloudRelPaths) {
        if (relPath.isEmpty) continue;
        final localInfo = localFiles[relPath];
        var remoteInfo = remoteFiles[relPath];
        
        // Secondary check: if we didn't find it by relPath, try looking up by full cloud path
        // because some files might still be keyed by their absolute remote name in the server response.
        if (remoteInfo == null) {
           final fullCloudPath = '$cloudPrefix/$relPath';
           remoteInfo = allRemoteFiles.firstWhere(
             (f) => (f['path'] as String).toLowerCase() == fullCloudPath.toLowerCase(), 
             orElse: () => null
           );
        }

        final String remotePath = remoteInfo != null ? remoteInfo['path'] : '$cloudPrefix/$relPath';
        
        String status = 'Synced';
        final type = (relPath.toLowerCase().contains('.state') ||
                relPath.toLowerCase().endsWith('.png'))
            ? 'State'
            : 'Save';

        if (localInfo == null) {
          status = 'Remote Only';
        } else if (remoteInfo == null) {
          final cached = await _syncStateDb.getState(localInfo['uri']);
          if (cached != null) {
            final int localTs = (localInfo['lastModified'] as num).toInt();
            final int localSize = (localInfo['size'] as num).toInt();
            // If the local file matches what's in the cache, it's 'Synced'
            // If it differs from the cache, it's 'Modified' locally since the last sync.
            if (cached['size'] == localSize && (cached['last_modified'] ~/ 1000) == (localTs ~/ 1000)) {
               status = 'Synced';
            } else {
               status = 'Modified';
            }
          } else {
            status = 'Local Only'; // Unseen by the DB
          }
        } else {
          final String remoteHash = remoteInfo['hash'];
          final int localTs = (localInfo['lastModified'] as num).toInt();
          final int localSize = (localInfo['size'] as num).toInt();

          if (isJournaledSynced(prefs, systemId.toLowerCase(), relPath, remoteHash, localTs: localTs)) {
            status = 'Synced';
          } else {
            final cached = await _syncStateDb.getState(localInfo['uri']);
            
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
              final int remoteTs = (remoteInfo['updated_at'] as num).toInt() ~/ 1000;
              final int localTsSec = localTs ~/ 1000;

              if (localSize != remoteInfo['size'] || localTsSec != remoteTs) {
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
