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
import '../services/local_versioning_service.dart';

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

  @visibleForTesting
  void recordSyncSuccess(SharedPreferences prefs, String systemId, String relPath, String hash, [int? localTs]) {
    final key = 'journal_${systemId.toLowerCase()}_$relPath';
    // Normalize timestamp to second-precision to avoid sub-second jitter loops on Linux
    final normalizedTs = localTs != null ? (localTs ~/ 1000) * 1000 : null;
    _pendingJournal[key] = normalizedTs != null ? '$normalizedTs:$hash' : hash;
  }

  Future<void> _commitSyncJournal(SharedPreferences prefs) async {
    if (_pendingJournal.isEmpty) return;
    await Future.wait(_pendingJournal.entries.map((e) => prefs.setString(e.key, e.value)));
    _pendingJournal.clear();
  }

  @visibleForTesting
  bool isJournaledSynced(SharedPreferences prefs, String systemId, String relPath, String remoteHash, {int? localTs}) {
    final key = 'journal_${systemId.toLowerCase()}_$relPath';
    final normalizedTs = localTs != null ? (localTs ~/ 1000) * 1000 : null;
    if (_pendingJournal.containsKey(key)) {
      final stored = _pendingJournal[key]!;
      if (normalizedTs != null) return stored == '$normalizedTs:$remoteHash';
      return stored == remoteHash || stored.endsWith(':$remoteHash');
    }
    return _conflictResolver.isJournaledSynced(prefs, systemId.toLowerCase(), relPath, remoteHash, localTs: normalizedTs);
  }

  // --- Local filesystem scan with 30s cache ---

  final Map<String, (List<dynamic>, DateTime)> _scanCache = {};
  static const _scanCacheTTL = Duration(seconds: 30);

  Future<List<dynamic>> _getCachedOrNewScan(String systemId, String effectivePath, List<String>? ignoredFolders, [List<String>? saveExtensions]) async {
    final cacheKey = '${systemId}_$effectivePath';
    final cached = _scanCache[cacheKey];
    if (cached != null && DateTime.now().difference(cached.$2) < _scanCacheTTL) {
      _lastScanList = cached.$1;
      return _lastScanList;
    }

    List<dynamic> result = [];
    try {
      if (Platform.isLinux || Platform.isWindows || Platform.isMacOS) {
        result = await DartFileScanner.scanRecursive(
          effectivePath,
          systemId,
          ignoredFolders ?? [],
          saveExtensions: saveExtensions ?? const [],
        );
      } else {
        final String jsonResult = await _platform.invokeMethod('scanRecursive', {
          'path': effectivePath,
          'systemId': systemId,
          'ignoredFolders': ignoredFolders ?? [],
          'saveExtensions': saveExtensions ?? const [],
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
    final now = DateTime.now();
    _scanCache[cacheKey] = (result, now);
    // Evict expired entries to prevent unbounded growth.
    _scanCache.removeWhere((_, v) => now.difference(v.$2) >= _scanCacheTTL);
    return result;
  }

  // --- Public API ---

  /// Resolves the folder to scan.
  ///
  /// [systemId] here is the CLOUD NAMESPACE, not the configured system: the
  /// RetroArch-backed systems (gba, snes, n64, ps1) all arrive as `RetroArch`.
  /// Re-resolving from it looks up `system_path_RetroArch`, which no user ever
  /// sets, and falls through to the hardcoded `/storage/emulated/0/RetroArch/saves`
  /// in suggestSavePath. That silently overrode whatever the caller had
  /// resolved, so `states/` was never scanned and no savestate on this device
  /// was ever backed up.
  ///
  /// Every caller already passes the effective path (sync_service,
  /// system_detail_screen and decky_bridge_service all call getEffectivePath
  /// with the real system id first), so prefer it and keep the lookup only as
  /// a fallback.
  @visibleForTesting
  static String pickScanRoot(String localPath, String resolvedFallback) =>
      localPath.isNotEmpty ? localPath : resolvedFallback;

  Future<String> _scanRootFor(String systemId, String localPath) async {
    // Short-circuits on purpose: getEffectivePath persists migrations, so it
    // should not run when the caller already resolved the root.
    if (localPath.isNotEmpty) return pickScanRoot(localPath, localPath);
    return _pathService.getEffectivePath(systemId);
  }

  Future<List<Map<String, dynamic>>> diffSystem(String systemId, String localPath, {List<String>? ignoredFolders, List<String>? saveExtensions}) async {
    final effectivePath = await _scanRootFor(systemId, localPath);
    try { await _pathService.mkdirs(effectivePath); } catch (_) {}
    return _diffService.diffSystem(
      systemId, localPath,
      effectivePath: effectivePath,
      getCachedOrNewScan: _getCachedOrNewScan,
      isJournaledSynced: isJournaledSynced,
      recordSyncSuccess: recordSyncSuccess,
      ignoredFolders: ignoredFolders,
      saveExtensions: saveExtensions,
    );

  }

  Future<void> syncSystem(String systemId, String localPath, {List<String>? ignoredFolders, List<String>? saveExtensions, Function(String)? onProgress, Function(String)? onError, String? filenameFilter, bool fastSync = false, bool Function()? isCancelled, bool ignoreConnectivity = false}) async {
    await _syncLock.protect(() async {
      final prefs = await SharedPreferences.getInstance();
      final effectivePath = await _scanRootFor(systemId, localPath);
      // Always evict the scan cache before syncing so we see saves that
      // happened after the last diffSystem/dashboard refresh (30s TTL window).
      _scanCache.remove('${systemId}_$effectivePath');
      final String cloudPrefix = (systemId.toLowerCase() == 'eden') ? 'switch' : (localPath.toLowerCase().contains('retroarch') ? 'RetroArch' : systemId);
      // Await the real connectivity answer instead of racing it: a
      // synchronous read(isOnlineProvider) is wrong in a fresh
      // ProviderContainer (always the case in the WorkManager background
      // isolate) because connectivityProvider's first value on Android
      // arrives asynchronously from a platform call. See resolveIsOnline's
      // doc comment for the measured evidence.
      final ref = _ref;
      final bool isOnline = ignoreConnectivity || (ref == null ? true : await resolveIsOnline(ref));

      try { await _pathService.mkdirs(effectivePath); } catch (e) {
        developer.log('⚠️ SYNC: Failed to ensure base path exists', name: 'VaultSync', level: 900, error: e);
      }

      final localList = await _getCachedOrNewScan(systemId, effectivePath, ignoredFolders, saveExtensions);
      final localFiles = _conflictResolver.processLocalFiles(systemId, localList);

      if (!isOnline) {
        developer.log('SYNC: Offline mode. Queuing local changes for $systemId', name: 'VaultSync', level: 800);
        try {
          final masterKey = await _getMasterKey();
          for (final entry in localFiles.entries) {
            final relPath = entry.key;
            final localInfo = entry.value;
            final int localTs = (localInfo['lastModified'] as num).toInt();
            final int localSize = (localInfo['size'] as num).toInt();
            final cached = await _syncStateDb.getState(localInfo['uri']);
            
            // Normalize for comparison
            final localTsSec = localTs ~/ 1000;
            final cachedTsSec = (cached?['last_modified'] as num? ?? 0).toInt() ~/ 1000;

            if (cached == null || cached['size'] != localSize || cachedTsSec != localTsSec) {
              onProgress?.call('Snapshotting $relPath...');
              final snapshotId = await _ref?.read(localVersioningServiceProvider).createSnapshot(systemId, localInfo['uri'], localSize, masterKey: masterKey);
              if (snapshotId == null) {
                throw Exception('Critical: Failed to create local snapshot for $relPath. Sync aborted to prevent data loss.');
              }

              await _syncStateDb.upsertState(
                localInfo['uri'], localSize, localTs, cached?['hash'] ?? '',
                'pending_offline_upload',
                systemId: systemId, remotePath: '$cloudPrefix/$relPath', relPath: relPath,
              );
            }
          }
        } catch (e) {
          developer.log('⚠️ SYNC: Failed to queue offline changes', name: 'VaultSync', level: 900, error: e);
        }
        return;
      }

      try {
        final fileList = await _diffService.fetchAllRemoteFiles(cloudPrefix);
        final actualPrefix = cloudPrefix.toLowerCase();

        final remoteFiles = <String, dynamic>{};
        for (var f in fileList) {
          final path = f['path'] as String;
          String rel = path;
          if (path.toLowerCase().startsWith('$actualPrefix/')) {
            rel = path.substring(actualPrefix.length + 1);
          } else {
            final sidPrefix = '${systemId.toLowerCase()}/';
            if (path.toLowerCase().startsWith(sidPrefix)) {
              rel = path.substring(sidPrefix.length);
            }
          }
          remoteFiles[rel] = f;
        }

        final cloudRelPaths = <String>{
          ...localFiles.keys,
          ...remoteFiles.keys
        };

        for (final relPath in cloudRelPaths) {
          if (isCancelled?.call() == true) { onProgress?.call('Sync Cancelled'); break; }
          if (relPath.isEmpty) continue;

          final localInfo = localFiles[relPath];
          final remoteInfo = remoteFiles[relPath];
          final remotePath = remoteInfo != null ? remoteInfo['path'] as String : '$cloudPrefix/$relPath';

          if (filenameFilter != null && !remotePath.contains(filenameFilter)) continue;
          if (localInfo != null && remoteInfo == null) {
            final int localTs = (localInfo['lastModified'] as num).toInt();
            final int localSize = (localInfo['size'] as num).toInt();
            final cached = await _syncStateDb.getState(localInfo['uri']);
            
            final localTsSec = localTs ~/ 1000;
            final cachedTsSec = (cached?['last_modified'] as num? ?? 0).toInt() ~/ 1000;

            if (cached != null && cached['size'] == localSize && cachedTsSec == localTsSec && cached['status'] == 'synced') {
              await _syncStateDb.upsertState(localInfo['uri'], localSize, localTs, cached['hash'], 'pending_upload', systemId: systemId, remotePath: remotePath, relPath: relPath, blockHashes: cached['block_hashes']);
            } else {
              onProgress?.call('Hashing $relPath...');
              final masterKey = await _getMasterKey();
              final combined = await _networkService.getBlockHashesAndFileHash(localInfo['uri'], masterKey);
              final blockHashes = (combined['blockHashes'] as List).cast<String>();
              final fullHash = await _hashService.getLocalHash(localInfo['uri'], localSize, localTs, precomputedHash: combined['fileHash'] as String);
              
              onProgress?.call('Snapshotting $relPath...');
              final snapshotId = await _ref?.read(localVersioningServiceProvider).createSnapshot(systemId, localInfo['uri'], localSize, masterKey: masterKey, currentBlockHashes: blockHashes, currentFileHash: fullHash);
              if (snapshotId == null) {
                throw Exception('Critical: Failed to create local snapshot for $relPath. Sync aborted to prevent data loss.');
              }

              await _syncStateDb.upsertState(localInfo['uri'], localSize, localTs, fullHash, 'pending_upload', systemId: systemId, remotePath: remotePath, relPath: relPath, blockHashes: json.encode(blockHashes));
            }
          } else if (localInfo == null && remoteInfo != null) {
            onProgress?.call('Queueing $relPath for download...');
            // relPath here is already stripped of cloudPrefix/ by the loop logic
            var destRelPath = _pathResolver.getLocalRelPath(systemId, '$cloudPrefix/$relPath', localFiles, _lastScanList, probedProfileId: (systemId.toLowerCase() == 'switch' || systemId.toLowerCase() == 'eden') ? await _pathService.probeProfileId(effectivePath) : null, localRoot: effectivePath);
            if (destRelPath == null) {
              // The resolver could not place this file under the configured
              // root without putting it in the wrong folder. It already logged
              // why; leaving the cloud copy untouched is the safe outcome.
              onError?.call('Skipped $relPath: it does not belong under the configured folder for $systemId');
              continue;
            }
            // Guard against a configured root that is one level too deep, which
            // would otherwise land the file in a self-nested copy of itself.
            final dedupedRelPath = SyncPathResolver.dedupeRootSegment(effectivePath, destRelPath);
            if (dedupedRelPath != destRelPath) {
              developer.log(
                  'SYNC: Root overlaps cloud path for $systemId — trimmed "$destRelPath" to "$dedupedRelPath" under $effectivePath',
                  name: 'VaultSync',
                  level: 900);
              destRelPath = dedupedRelPath;
            }
            final destUri = p.join(effectivePath, destRelPath);
            developer.log('SYNC: Queueing download: $relPath -> $destUri', name: 'VaultSync', level: 800);
            await _syncStateDb.upsertState(destUri, remoteInfo['size'], remoteInfo['updated_at'], remoteInfo['hash'], 'pending_download', systemId: systemId, remotePath: remotePath, relPath: destRelPath);
          }
 else if (localInfo != null && remoteInfo != null) {
            final String remoteHash = remoteInfo['hash'];
            final int localTs = (localInfo['lastModified'] as num).toInt();
            final int localSize = (localInfo['size'] as num).toInt();

            // Never let an empty local file replace a non-empty cloud copy. A save
            // that reads as 0 bytes is a failure signal, not an edit: a stale SAF
            // index listing files that no longer exist produced 23 such phantoms,
            // all of which were uploaded over their real counterparts. Skipping
            // leaves the good remote copy intact; the next sync re-evaluates.
            if (localSize == 0 && (remoteInfo['size'] as num).toInt() > 0) {
              developer.log(
                  'SYNC: Refusing to upload empty $relPath over a ${remoteInfo['size']}-byte cloud copy',
                  name: 'VaultSync',
                  level: 1000);
              onError?.call('Skipped $relPath: local file is empty but the cloud copy is not');
              continue;
            }

            final cached = await _syncStateDb.getState(localInfo['uri']);
            // Only trust the "already synced" fast-paths when the local file has NOT
            // changed since we last recorded it: same size AND its mtime hasn't advanced
            // past the cached sync time. Without this guard, a locally-MODIFIED save (the
            // user played again) whose *previously*-synced hash still matched the server
            // copy was silently skipped and never re-uploaded — the journal/DB hash equalled
            // the remote hash, so both shortcuts fired even though the on-disk file was newer.
            // A genuine edit always advances mtime (and usually size), so it now falls through
            // to the block-hash path below and uploads. Cost is at most ONE re-hash after a
            // change/download — the hash path re-writes the cache with the real local mtime,
            // so subsequent syncs skip again (no re-hash-every-sync regression).
            final int cachedTsSec = (cached?['last_modified'] as num? ?? 0).toInt() ~/ 1000;
            final bool localUnchanged = cached != null
                && (cached['size'] as num?)?.toInt() == localSize
                && (localTs ~/ 1000) <= cachedTsSec;

            // Zero-size metadata is where stale SAF metadata is suspected to bite:
            // on-device, a Switch save that was 4012 bytes on disk was never
            // uploaded over a 0-byte server copy, and the only branch consistent
            // with the DB state is a scan reporting 0 bytes (inferred, not yet
            // observed directly). The shortcuts below (journal + DB-cached hash match) only compare metadata/
            // journal entries against each other, never actual file content, so when
            // either side is reporting size 0 they cannot tell a real empty file from
            // bad scan metadata. Skip both shortcuts in that case and fall through to
            // hashing the real bytes.
            final bool zeroSizeInvolved = localSize == 0 || (remoteInfo['size'] as num).toInt() == 0;

            if (!zeroSizeInvolved && localUnchanged && isJournaledSynced(prefs, systemId, relPath, remoteHash)) continue;
            // Primary: hash + synced status match is sufficient — SAF/content:// paths
            // cannot reliably set lastModified after a download, so timestamp matching
            // would always fail and trigger an expensive re-hash on every subsequent sync.
            if (!zeroSizeInvolved && localUnchanged && cached['hash'] == remoteHash && cached['status'] == 'synced') {
              recordSyncSuccess(prefs, systemId, relPath, remoteHash, localTs);
              developer.log('SYNC: DB-cached synced (hash match, local unchanged) — skipping $relPath', name: 'VaultSync', level: 800);
              continue;
            }
            onProgress?.call('Checking $relPath blocks...');
            final masterKey = await _getMasterKey();
            final List<String> currentBlockHashes;
            final String localHash;
            // Use cached hash if available (one read for block hashes only);
            // otherwise single-pass combined method (one read instead of two).
            // The (uri, size, lastModified)-keyed hash cache is bypassed entirely when
            // zeroSizeInvolved: it is keyed on the very same untrustworthy size, so a
            // prior lookup at (uri, 0, ts) could hand back a stale hash — e.g. one
            // cached the last time this same bad scan metadata was seen — masking a
            // real content change. Read+hash the actual bytes every time instead, and
            // skip writing the result back into that cache too (getLocalHash's own
            // internal cache read has the identical staleness problem), so a later
            // sync with correct metadata always gets a fresh answer.
            final cachedHash = zeroSizeInvolved ? null : await _hashService.getCachedHash(localInfo['uri'], localSize, localTs);
            if (cachedHash != null) {
              currentBlockHashes = await _networkService.getBlockHashes(localInfo['uri'], masterKey);
              localHash = cachedHash;
            } else {
              final combined = await _networkService.getBlockHashesAndFileHash(localInfo['uri'], masterKey);
              currentBlockHashes = (combined['blockHashes'] as List).cast<String>();
              localHash = zeroSizeInvolved
                  ? combined['fileHash'] as String
                  : await _hashService.getLocalHash(localInfo['uri'], localSize, localTs, precomputedHash: combined['fileHash'] as String);
            }
            if (localHash == remoteHash) {
              await _syncStateDb.upsertState(localInfo['uri'], localSize, localTs, localHash, 'synced', systemId: systemId, remotePath: remotePath, relPath: relPath, blockHashes: json.encode(currentBlockHashes));
              recordSyncSuccess(prefs, systemId, relPath, remoteHash, localTs);
              developer.log('SYNC: Hash matched — marking synced $relPath', name: 'VaultSync', level: 800);
              continue;
            }
            developer.log('SYNC: Hash mismatch for $relPath — local=$localHash remote=$remoteHash', name: 'VaultSync', level: 900);
            onProgress?.call('Snapshotting $relPath...');
            final snapshotId = await _ref?.read(localVersioningServiceProvider).createSnapshot(systemId, localInfo['uri'], localSize, masterKey: masterKey, currentBlockHashes: currentBlockHashes, currentFileHash: localHash);
            if (snapshotId == null) {
              throw Exception('Critical: Failed to create local snapshot for $relPath. Sync aborted to prevent data loss.');
            }

            final int remoteTsSec = (remoteInfo['updated_at'] as num).toInt() ~/ 1000;
            final int localTsSecToCompare = localTs ~/ 1000;

            if (localTsSecToCompare >= remoteTsSec) {
              onProgress?.call('Queueing $relPath for patching (Local Newer)...');
              await _syncStateDb.upsertState(localInfo['uri'], localSize, localTs, localHash, 'pending_upload', systemId: systemId, remotePath: remotePath, relPath: relPath, blockHashes: json.encode(currentBlockHashes));
            } else {
              onProgress?.call('Queueing $relPath for patching (Cloud Newer)...');
              // Use originalRelPath (local-relative) so the job queue passes the correct
              // path to Kotlin's downloadFile. Using the cloud-relative relPath here
              // would cause the file to be written to a ghost location (e.g. missing
              // the Switch profile-ID directory).
              final localRelPath = (localInfo['originalRelPath'] as String?) ?? relPath;
              // Store remote size/timestamp/hash so the job queue uses the correct
              // values for fileSize (block calculation) and records the right hash
              // after download. blockHashes are the LOCAL hashes for delta patching.
              await _syncStateDb.upsertState(localInfo['uri'], (remoteInfo['size'] as num).toInt(), (remoteInfo['updated_at'] as num).toInt(), remoteHash, 'pending_download', systemId: systemId, remotePath: remotePath, relPath: localRelPath, blockHashes: json.encode(currentBlockHashes));
            }
          }
        }

        await _jobQueue.process(systemId, effectivePath, onProgress,
          getDeviceName: _getDeviceName,
          recordSyncSuccess: recordSyncSuccess, getMasterKey: () async => await _getMasterKey(),
          isCancelled: isCancelled,
        );
        await _commitSyncJournal(prefs);
      } catch (e, stack) {
        developer.log('SYNC ERROR ($systemId): $e\n$stack', name: 'VaultSync', level: 1000);
        _ref?.read(notificationLogProvider.notifier).addError(e, systemId: systemId);
        onError?.call(e.toString());
        rethrow;
      }
    });
  }

  Future<void> processManualQueue() async {
    await _jobQueue.processManual(
      getDeviceName: _getDeviceName,
      recordSyncSuccess: recordSyncSuccess, getMasterKey: () async => await _getMasterKey(),
    );
  }

  Future<void> restoreOfflineQueue() async {
    await _syncStateDb.markOfflineJobsAsPending();
  }

  Future<void> uploadFile(dynamic localPathOrFile, String remotePath, {required String systemId, required String relPath, required SharedPreferences prefs, String? plainHash, List<String>? localBlockHashes, bool force = false}) async {
    final path = localPathOrFile is File ? localPathOrFile.path : localPathOrFile.toString();
    
    String? rommKey;
    String? rommUrl;
    String? rommApiKey;
    if (prefs.getBool('romm_sync_enabled') ?? false) {
      rommKey = await _getMasterKey();
      rommUrl = prefs.getString('romm_url');
      rommApiKey = prefs.getString('romm_api_key');
      developer.log('SYNC: Attaching RomM Key for $relPath', name: 'VaultSync', level: 800);
    }

    await _networkService.uploadFile(
      path, remotePath, 
      systemId: systemId, 
      relPath: relPath, 
      deviceName: await _getDeviceName(), 
      onRecordSuccess: (sid, rp, h, ts) => recordSyncSuccess(prefs, sid, rp, h, ts),
      plainHash: plainHash,
      localBlockHashes: localBlockHashes, 
      force: force,
      rommKey: rommKey,
      rommUrl: rommUrl,
      rommApiKey: rommApiKey,
    );

  }

  Future<dynamic> downloadFile(String remotePath, String localBasePath, String relPath, {required String systemId, required SharedPreferences prefs, required int fileSize, String? remoteHash, int? updatedAt, dynamic serverBlocks, String? localUri}) async {
    return await _networkService.downloadFile(remotePath, localBasePath, relPath, systemId: systemId, fileSize: fileSize, onRecordSuccess: (sid, rp, h, ts) => recordSyncSuccess(prefs, sid, rp, h, ts), remoteHash: remoteHash, updatedAt: updatedAt, serverBlocks: serverBlocks, localUri: localUri);
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

  /// Handles one server-sent change notification.
  ///
  /// Returns the systemId that needs syncing, or null when the event is
  /// irrelevant (our own upload echoed back, or a system this device does not
  /// have configured). The caller turns that into a real sync.
  ///
  /// This deliberately does NOT resolve the local destination or queue anything
  /// itself. It used to, and both halves were broken: the resolution ran against
  /// `_lastScanList`, which is only populated by a scan, so before the first
  /// sync of a session it was empty and rules keyed on it (`hasFilesDir`,
  /// `isRooted`) silently produced a *different* destination than a real sync
  /// would; and nothing ever drained the queue it wrote, so the file sat in
  /// `pending_download` — the user saw "New save available" and no download.
  Future<String?> handleRemoteEvent(Map<String, dynamic> data) async {
    final String path = data['path'];
    final String systemId = data['system_id'];
    final String originDevice = data['origin_device'];

    if (originDevice == await getDeviceNameInternal()) return null;

    final paths = await _pathService.getAllSystemPaths();
    if (!paths.containsKey(systemId)) return null;

    _ref?.read(notificationLogProvider.notifier).addNotification(
      title: 'Remote Update',
      message: 'New save available for ${systemId.toUpperCase()}: ${path.split("/").last}',
      type: NotificationType.info,
      systemId: systemId,
    );

    return systemId;
  }
}


