import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mutex/mutex.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:meta/meta.dart';
import 'file_cache.dart';
import 'dart_file_scanner.dart';
import 'dart_native_crypto.dart';
import 'sync_state_database.dart';
import 'switch_profile_resolver.dart';
import 'sync_diff_service.dart';
import 'sync_job_queue.dart';
import '../../../core/services/connectivity_provider.dart';
import '../domain/notification_models.dart';
import '../domain/notification_provider.dart';
import '../services/sync_network_service.dart';
import '../services/sync_path_resolver.dart';
import '../services/system_path_service.dart';
import '../../../core/services/api_client.dart';
import '../../../core/services/api_client_provider.dart';

import '../services/file_hash_service.dart';
import '../services/conflict_resolver.dart';
import '../services/notification_service.dart';
import '../services/power_manager_service.dart';

final syncPathResolverProvider = Provider<SyncPathResolver>((ref) => SyncPathResolver());
final syncStateDatabaseProvider = Provider<SyncStateDatabase>((ref) => SyncStateDatabase());

final fileHashServiceProvider = Provider<FileHashService>((ref) {
  return FileHashService(FileCache());
});

final conflictResolverProvider = Provider<ConflictResolver>((ref) {
  final pathResolver = ref.watch(syncPathResolverProvider);
  return ConflictResolver(pathResolver);
});

final notificationServiceProvider = Provider<NotificationService>((ref) {
  return NotificationService();
});

final powerManagerServiceProvider = Provider<PowerManagerService>((ref) {
  return PowerManagerService();
});

final syncNetworkServiceProvider = Provider<SyncNetworkService>((ref) {
  final apiClient = ref.watch(apiClientProvider);
  return SyncNetworkService(apiClient);
});

final syncDiffServiceProvider = Provider<SyncDiffService>((ref) {
  return SyncDiffService(
    ref.watch(apiClientProvider),
    ref.watch(conflictResolverProvider),
    ref.watch(syncStateDatabaseProvider),
    ref.watch(syncPathResolverProvider),
    ref,
  );
});

final syncRepositoryProvider = Provider<SyncRepository>((ref) {
  final apiClient = ref.watch(apiClientProvider);
  final pathService = ref.watch(systemPathServiceProvider);
  final networkService = ref.watch(syncNetworkServiceProvider);
  final pathResolver = ref.watch(syncPathResolverProvider);
  final syncStateDb = ref.watch(syncStateDatabaseProvider);
  final hashService = ref.watch(fileHashServiceProvider);
  final conflictResolver = ref.watch(conflictResolverProvider);
  final switchResolver = ref.watch(switchProfileResolverProvider);
  final diffService = ref.watch(syncDiffServiceProvider);
  final jobQueue = SyncJobQueue(syncStateDb, networkService, pathService, ref);
  return SyncRepository(
    apiClient, pathService, FileCache(), networkService, pathResolver,
    syncStateDb, hashService, conflictResolver, switchResolver, diffService, jobQueue, ref,
  ); // ref is Ref? — passed as the last required nullable arg
});

/// Coordinates emulator save synchronization between the local filesystem and
/// the VaultSync server. Delegates specialised concerns to:
/// - [SwitchProfileResolver] — Nintendo Switch profile ID fixup
/// - [SyncDiffService] — diff computation and remote file listing
/// - [SyncJobQueue] — upload/download job processing with retry
class SyncRepository {
  final ApiClient _apiClient;
  final SystemPathService _pathService;
  final FileCache _fileCache;
  final SyncNetworkService _networkService;
  final SyncPathResolver _pathResolver;
  final SyncStateDatabase _syncStateDb;
  final FileHashService _hashService;
  final ConflictResolver _conflictResolver;
  final SwitchProfileResolver _switchResolver;
  final SyncDiffService _diffService;
  final SyncJobQueue _jobQueue;
  final Ref? _ref;
  static const _platform = MethodChannel('com.vaultsync.app/launcher');
  final _syncLock = Mutex();

  String? _cachedDeviceName;
  List<dynamic> _lastScanList = [];

  SyncRepository(
    this._apiClient, this._pathService, this._fileCache, this._networkService,
    this._pathResolver, this._syncStateDb, this._hashService, this._conflictResolver,
    this._switchResolver, this._diffService, this._jobQueue, this._ref,
  );

  Future<String> _getDeviceName() async => getDeviceNameInternal();

  @visibleForTesting
  Future<String> getDeviceNameInternal() async {
    if (_cachedDeviceName != null) return _cachedDeviceName!;
    final deviceInfo = DeviceInfoPlugin();
    if (Platform.isAndroid) {
      _cachedDeviceName = (await deviceInfo.androidInfo).model;
    } else if (Platform.isWindows) {
      _cachedDeviceName = (await deviceInfo.windowsInfo).computerName;
    } else if (Platform.isLinux) {
      _cachedDeviceName = (await deviceInfo.linuxInfo).prettyName;
    }
    return _cachedDeviceName ?? 'Unknown Device';
  }

  // --- Sync journal (in-memory write-back cache for SharedPreferences) ---

  final Map<String, String> _pendingJournal = {};

  void _recordSyncSuccess(SharedPreferences prefs, String systemId, String relPath, String hash, [int? localTs]) {
    _pendingJournal['journal_${systemId}_$relPath'] = localTs != null ? '$localTs:$hash' : hash;
  }

  Future<void> _commitSyncJournal(SharedPreferences prefs) async {
    if (_pendingJournal.isEmpty) return;
    await Future.wait(_pendingJournal.entries.map((e) => prefs.setString(e.key, e.value)));
    _pendingJournal.clear();
  }

  bool _isJournaledSynced(SharedPreferences prefs, String systemId, String relPath, String remoteHash, {int? localTs}) {
    final key = 'journal_${systemId}_$relPath';
    if (_pendingJournal.containsKey(key)) {
      final stored = _pendingJournal[key]!;
      if (localTs != null) return stored == '$localTs:$remoteHash';
      return stored == remoteHash || stored.endsWith(':$remoteHash');
    }
    return _conflictResolver.isJournaledSynced(prefs, systemId, relPath, remoteHash, localTs: localTs);
  }

  // --- Local filesystem scan with 30s cache ---

  final Map<String, (List<dynamic>, DateTime)> _scanCache = {};
  static const _scanCacheTTL = Duration(seconds: 30);

  Future<List<dynamic>> _getCachedOrNewScan(String systemId, String effectivePath, List<String>? ignoredFolders) async {
    final cacheKey = '${systemId}_$effectivePath';
    final cached = _scanCache[cacheKey];
    if (cached != null && DateTime.now().difference(cached.$2) < _scanCacheTTL) {
      _lastScanList = cached.$1;
      return _lastScanList;
    }

    List<dynamic> result = [];
    try {
      if (Platform.isLinux || Platform.isWindows || Platform.isMacOS) {
        result = await DartFileScanner.scanRecursive(effectivePath, systemId, ignoredFolders ?? []);
      } else {
        final String jsonResult = await _platform.invokeMethod('scanRecursive', {
          'path': effectivePath, 'systemId': systemId, 'ignoredFolders': ignoredFolders ?? [],
        });
        result = json.decode(jsonResult);
      }
    } catch (e) {
      developer.log('⚠️ SCAN: Path does not exist or inaccessible: $effectivePath', name: 'VaultSync', level: 900, error: e);
    }

    final sid = systemId.toLowerCase();
    if (sid == 'switch' || sid == 'eden') {
      result = await _switchResolver.applyProfileFixes(result, effectivePath);
    }

    _lastScanList = result;
    _scanCache[cacheKey] = (result, DateTime.now());
    return result;
  }

  // --- Public API ---

  Future<List<Map<String, dynamic>>> diffSystem(String systemId, String localPath, {List<String>? ignoredFolders}) async {
    final effectivePath = await _pathService.getEffectivePath(systemId);
    try { await _pathService.mkdirs(effectivePath); } catch (_) {}
    return _diffService.diffSystem(
      systemId, localPath,
      effectivePath: effectivePath,
      getCachedOrNewScan: _getCachedOrNewScan,
      isJournaledSynced: _isJournaledSynced,
      recordSyncSuccess: _recordSyncSuccess,
      ignoredFolders: ignoredFolders,
    );
  }

  Future<void> syncSystem(String systemId, String localPath, {List<String>? ignoredFolders, Function(String)? onProgress, Function(String)? onError, String? filenameFilter, bool fastSync = false, bool Function()? isCancelled, bool ignoreConnectivity = false}) async {
    await _syncLock.protect(() async {
      final prefs = await SharedPreferences.getInstance();
      final effectivePath = await _pathService.getEffectivePath(systemId);
      final String cloudPrefix = (systemId.toLowerCase() == 'eden') ? 'switch' : (localPath.toLowerCase().contains('retroarch') ? 'RetroArch' : systemId);
      final bool isOnline = ignoreConnectivity || (_ref?.read(isOnlineProvider) ?? true);

      try { await _pathService.mkdirs(effectivePath); } catch (e) {
        developer.log('⚠️ SYNC: Failed to ensure base path exists', name: 'VaultSync', level: 900, error: e);
      }

      if (!isOnline) {
        developer.log('SYNC: Offline mode. Queuing local changes for $systemId', name: 'VaultSync', level: 800);
        final localList = await _getCachedOrNewScan(systemId, effectivePath, ignoredFolders);
        final localFiles = _conflictResolver.processLocalFiles(systemId, localList);
        for (final entry in localFiles.entries) {
          final relPath = entry.key;
          final localInfo = entry.value;
          final int localTs = (localInfo['lastModified'] as num).toInt();
          final int localSize = (localInfo['size'] as num).toInt();
          final cached = await _syncStateDb.getState(localInfo['uri']);
          if (cached == null || cached['size'] != localSize || cached['last_modified'] != localTs) {
            await _syncStateDb.upsertState(
              localInfo['uri'], localSize, localTs, cached?['hash'] ?? '',
              'pending_offline_upload',
              systemId: systemId, remotePath: '$cloudPrefix/$relPath', relPath: relPath,
            );
          }
        }
        return;
      }

      try {
        final fileList = await _diffService.fetchAllRemoteFiles(cloudPrefix);
        final remoteFiles = {for (var f in fileList) f['path']: f};
        final localList = await _getCachedOrNewScan(systemId, effectivePath, ignoredFolders);
        final localFiles = _conflictResolver.processLocalFiles(systemId, localList);
        final cloudRelPaths = <String>{
          ...localFiles.keys,
          ...remoteFiles.keys.map((p) => p.substring(cloudPrefix.length + 1)),
        };

        for (final relPath in cloudRelPaths) {
          if (isCancelled?.call() == true) { onProgress?.call('Sync Cancelled'); break; }
          if (relPath.isEmpty) continue;
          final remotePath = '$cloudPrefix/$relPath';
          if (filenameFilter != null && !remotePath.contains(filenameFilter)) continue;
          final localInfo = localFiles[relPath];
          final remoteInfo = remoteFiles[remotePath];

          if (localInfo != null && remoteInfo == null) {
            final int localTs = (localInfo['lastModified'] as num).toInt();
            final int localSize = (localInfo['size'] as num).toInt();
            final cached = await _syncStateDb.getState(localInfo['uri']);
            if (cached != null && cached['size'] == localSize && cached['last_modified'] == localTs && cached['status'] == 'synced') {
              await _syncStateDb.upsertState(localInfo['uri'], localSize, localTs, cached['hash'], 'pending_upload', systemId: systemId, remotePath: remotePath, relPath: relPath, blockHashes: cached['block_hashes']);
            } else {
              onProgress?.call('Hashing $relPath...');
              final masterKey = await _getMasterKey();
              final combined = await _networkService.getBlockHashesAndFileHash(localInfo['uri'], masterKey);
              final blockHashes = (combined['blockHashes'] as List).cast<String>();
              final fullHash = await _hashService.getLocalHash(localInfo['uri'], localSize, localTs, precomputedHash: combined['fileHash'] as String);
              await _syncStateDb.upsertState(localInfo['uri'], localSize, localTs, fullHash, 'pending_upload', systemId: systemId, remotePath: remotePath, relPath: relPath, blockHashes: json.encode(blockHashes));
            }
          } else if (localInfo == null && remoteInfo != null) {
            onProgress?.call('Queueing $relPath for download...');
            final destRelPath = _pathResolver.getLocalRelPath(systemId, relPath, localFiles, _lastScanList, probedProfileId: (systemId.toLowerCase() == 'switch' || systemId.toLowerCase() == 'eden') ? await _pathService.probeProfileId(effectivePath) : null);
            final destUri = p.join(effectivePath, destRelPath);
            developer.log('SYNC: Queueing download: $relPath -> $destUri', name: 'VaultSync', level: 800);
            await _syncStateDb.upsertState(destUri, remoteInfo['size'], remoteInfo['updated_at'], remoteInfo['hash'], 'pending_download', systemId: systemId, remotePath: remotePath, relPath: destRelPath);
          } else if (localInfo != null && remoteInfo != null) {
            final String remoteHash = remoteInfo['hash'];
            final int localTs = (localInfo['lastModified'] as num).toInt();
            final int localSize = (localInfo['size'] as num).toInt();
            if (_isJournaledSynced(prefs, systemId, relPath, remoteHash, localTs: localTs)) continue;
            final cached = await _syncStateDb.getState(localInfo['uri']);
            if (cached != null && cached['size'] == localSize && (cached['last_modified'] ~/ 1000) == (localTs ~/ 1000) && cached['hash'] == remoteHash && cached['status'] == 'synced') {
              _recordSyncSuccess(prefs, systemId, relPath, remoteHash, localTs);
              continue;
            }
            onProgress?.call('Checking $relPath blocks...');
            final masterKey = await _getMasterKey();
            final List<String> currentBlockHashes;
            final String localHash;
            // Use cached hash if available (one read for block hashes only);
            // otherwise single-pass combined method (one read instead of two).
            final cachedHash = await _hashService.getCachedHash(localInfo['uri'], localSize, localTs);
            if (cachedHash != null) {
              currentBlockHashes = await _networkService.getBlockHashes(localInfo['uri'], masterKey);
              localHash = cachedHash;
            } else {
              final combined = await _networkService.getBlockHashesAndFileHash(localInfo['uri'], masterKey);
              currentBlockHashes = (combined['blockHashes'] as List).cast<String>();
              localHash = await _hashService.getLocalHash(localInfo['uri'], localSize, localTs, precomputedHash: combined['fileHash'] as String);
            }
            if (localHash == remoteHash) {
              await _syncStateDb.upsertState(localInfo['uri'], localSize, localTs, localHash, 'synced', systemId: systemId, remotePath: remotePath, relPath: relPath, blockHashes: json.encode(currentBlockHashes));
              _recordSyncSuccess(prefs, systemId, relPath, remoteHash, localTs);
              continue;
            }
            if (localTs > (remoteInfo['updated_at'] as num)) {
              onProgress?.call('Queueing $relPath for patching (Local Newer)...');
              await _syncStateDb.upsertState(localInfo['uri'], localSize, localTs, localHash, 'pending_upload', systemId: systemId, remotePath: remotePath, relPath: relPath, blockHashes: json.encode(currentBlockHashes));
            } else {
              onProgress?.call('Queueing $relPath for patching (Cloud Newer)...');
              // Use originalRelPath (local-relative) so the job queue passes the correct
              // path to Kotlin's downloadFile. Using the cloud-relative relPath here
              // would cause the file to be written to a ghost location (e.g. missing
              // the Switch profile-ID directory).
              final localRelPath = (localInfo['originalRelPath'] as String?) ?? relPath;
              await _syncStateDb.upsertState(localInfo['uri'], localSize, localTs, localHash, 'pending_download', systemId: systemId, remotePath: remotePath, relPath: localRelPath, blockHashes: json.encode(currentBlockHashes));
            }
          }
        }

        await _jobQueue.process(systemId, effectivePath, onProgress,
          getDeviceName: _getDeviceName,
          recordSyncSuccess: _recordSyncSuccess,
          isCancelled: isCancelled,
        );
        await _commitSyncJournal(prefs);
      } catch (e) {
        developer.log('SYNC ERROR', name: 'VaultSync', level: 1000, error: e);
        _ref?.read(notificationLogProvider.notifier).addError(e, systemId: systemId);
        onError?.call(e.toString());
        rethrow;
      }
    });
  }

  Future<void> processManualQueue() async {
    await _jobQueue.processManual(
      getDeviceName: _getDeviceName,
      recordSyncSuccess: _recordSyncSuccess,
    );
  }

  Future<void> restoreOfflineQueue() async {
    await _syncStateDb.markOfflineJobsAsPending();
  }

  Future<void> uploadFile(dynamic localPathOrFile, String remotePath, {required String systemId, required String relPath, required SharedPreferences prefs, String? plainHash, List<String>? localBlockHashes, bool force = false}) async {
    final path = localPathOrFile is File ? localPathOrFile.path : localPathOrFile.toString();
    await _networkService.uploadFile(path, remotePath, systemId: systemId, relPath: relPath, deviceName: await _getDeviceName(), onRecordSuccess: (sid, rp, h) => _recordSyncSuccess(prefs, sid, rp, h), plainHash: plainHash, localBlockHashes: localBlockHashes, force: force);
  }

  Future<dynamic> downloadFile(String remotePath, String localBasePath, String relPath, {required String systemId, required SharedPreferences prefs, required int fileSize, String? remoteHash, int? updatedAt, dynamic serverBlocks, String? localUri}) async {
    return await _networkService.downloadFile(remotePath, localBasePath, relPath, systemId: systemId, fileSize: fileSize, onRecordSuccess: (sid, rp, h) => _recordSyncSuccess(prefs, sid, rp, h), remoteHash: remoteHash, updatedAt: updatedAt, serverBlocks: serverBlocks, localUri: localUri);
  }

  Future<void> deleteRemoteFile(String path) async { await _apiClient.delete('/api/v1/files', body: {'filename': path}); }
  Future<List<Map<String, dynamic>>> getFileVersions(String remotePath) async { final response = await _apiClient.get('/api/v1/versions?path=$remotePath'); return List<Map<String, dynamic>>.from(response['versions'] ?? []); }
  Future<void> restoreVersion(String remotePath, String versionId, String localBasePath, String relPath, int fileSize) async { await _networkService.restoreVersion(remotePath, versionId, localBasePath, relPath, fileSize); }
  Future<void> deleteSystemCloudData(String systemId) async { await _apiClient.delete('/api/v1/systems/$systemId'); }
  Future<List<Map<String, dynamic>>> getAllRemoteConflicts() async { try { final response = await _apiClient.get('/api/v1/conflicts'); return List<Map<String, dynamic>>.from(response['conflicts'] ?? []); } catch(_) { return []; } }

  Future<String?> _getMasterKey() async => await _apiClient.getEncryptionKey();

  Future<Map<String, dynamic>> scanLocalFiles(String path, String systemId) async {
    List<dynamic> list;
    if (Platform.isLinux || Platform.isWindows || Platform.isMacOS) {
      list = await DartFileScanner.scanRecursive(path, systemId, []);
    } else {
      final String result = await _platform.invokeMethod('scanRecursive', {'path': path, 'systemId': systemId});
      list = json.decode(result);
    }
    return _conflictResolver.processLocalFiles(systemId, list);
  }

  Future<void> handleRemoteEvent(Map<String, dynamic> data) async {
    final String path = data['path'];
    final String systemId = data['system_id'];
    final String originDevice = data['origin_device'];
    final String remoteHash = data['hash'];
    final int size = data['size'];
    final int updatedAt = data['updated_at'];

    if (originDevice == await getDeviceNameInternal()) return;

    final paths = await _pathService.getAllSystemPaths();
    if (!paths.containsKey(systemId)) return;

    final destRelPath = _pathResolver.getLocalRelPath(systemId, path.split('/').skip(1).join('/'), {}, _lastScanList, probedProfileId: (systemId.toLowerCase() == 'switch' || systemId.toLowerCase() == 'eden') ? await _pathService.probeProfileId(await _pathService.getEffectivePath(systemId)) : null);
    final effectivePath = await _pathService.getEffectivePath(systemId);
    final destUri = p.join(effectivePath, destRelPath);

    await _syncStateDb.upsertState(
      destUri, size, updatedAt, remoteHash, 'pending_download',
      systemId: systemId, remotePath: path, relPath: destRelPath,
    );

    _ref?.read(notificationLogProvider.notifier).addNotification(
      title: 'Remote Update',
      message: 'New save available for ${systemId.toUpperCase()}: ${path.split("/").last}',
      type: NotificationType.info,
      systemId: systemId,
    );
  }
}
