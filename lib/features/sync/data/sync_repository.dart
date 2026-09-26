import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mutex/mutex.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:path/path.dart' as p;
import '../../../core/errors/error_mapper.dart';
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

  /// Overridable so unit tests (which never run on real Android) can exercise
  /// the native device-name lookup branch of [getDeviceNameInternal] without
  /// a real device. Defaults to the real platform check everywhere else.
  final bool _isAndroid;

  String? _cachedDeviceName;
  List<dynamic> _lastScanList = [];

  SyncRepository(
    this._apiClient, this._pathService, this._fileCache, this._networkService,
    this._pathResolver, this._syncStateDb, this._hashService, this._conflictResolver,
    this._switchResolver, this._diffService, this._jobQueue, this._ref, {
    @visibleForTesting bool? isAndroidOverride,
  }) : _isAndroid = isAndroidOverride ?? Platform.isAndroid;

  /// SharedPreferences key for an optional user-set device name override.
  /// When present and non-blank this always wins — it is how a device whose
  /// raw model reports as an unrecognisable code (e.g. a POCO F8 Pro
  /// reporting as "2510DPC44G") can be given a name a user actually
  /// recognises in the server's device list.
  static const String kDeviceNameOverridePrefKey = 'device_name_override';

  Future<String> _getDeviceName() async => getDeviceNameInternal();

  /// Resolves this device's display name, in order:
  ///  1. [kDeviceNameOverridePrefKey], if the user has set one.
  ///  2. On Android, the user-set name from Settings > About phone > Device
  ///     name (`Settings.Global.DEVICE_NAME`, read via the native
  ///     `getDeviceSettingsName` method — no permission required). Android
  ///     otherwise reports the raw, often unrecognisable, model/build code.
  ///  3. The previous behaviour: `device_info_plus`'s model/computerName/
  ///     prettyName (desktop platforms keep this unchanged).
  ///
  /// This is also what [handleRemoteEvent] compares an incoming SSE event's
  /// `origin_device` against to skip the device's own echoed changes, so both
  /// sides of that comparison always resolve through this one method.
  @visibleForTesting
  Future<String> getDeviceNameInternal() async {
    if (_cachedDeviceName != null) return _cachedDeviceName!;

    final prefs = await SharedPreferences.getInstance();
    final override = prefs.getString(kDeviceNameOverridePrefKey)?.trim();
    if (override != null && override.isNotEmpty) {
      _cachedDeviceName = override;
      return _cachedDeviceName!;
    }

    if (_isAndroid) {
      try {
        final settingsName =
            await _platform.invokeMethod<String>('getDeviceSettingsName');
        final trimmed = settingsName?.trim();
        if (trimmed != null && trimmed.isNotEmpty) {
          _cachedDeviceName = trimmed;
          return _cachedDeviceName!;
        }
      } catch (e) {
        developer.log('DEVICE: getDeviceSettingsName failed',
            name: 'VaultSync', level: 800, error: e);
      }
    }

    final deviceInfo = DeviceInfoPlugin();
    if (_isAndroid) {
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

      final bool pathAlreadyExisted = await _pathService.pathExists(effectivePath);
      bool mkdirsOk = pathAlreadyExisted;
      if (!pathAlreadyExisted) {
        try {
          mkdirsOk = await _pathService.mkdirs(effectivePath);
        } catch (e) {
          developer.log('⚠️ SYNC: Failed to ensure base path exists', name: 'VaultSync', level: 900, error: e);
          mkdirsOk = false;
        }
      }

      // The folder doesn't exist and VaultSync couldn't create it. When it
      // lives under another app's Android/data/<package> directory (a
      // SAF-gated location, checked purely by path shape — see
      // SystemPathService.safNeededFor), that almost always means the
      // emulator itself hasn't been run yet to create its own files
      // directory (e.g. Flycast installed but never opened): VaultSync has
      // no way to create another app's private folder under scoped storage.
      // A `content://` path is excluded here because a granted SAF tree
      // always reports mkdirsOk=true (see the Kotlin `mkdirs` handler) — its
      // absence is a revoked/stale grant, handled separately by
      // ensureSafPermission, not this case. Skip this one system with a
      // specific, actionable reason instead of silently scanning nothing and
      // reporting a hollow "success" — and without aborting the other
      // configured systems (the caller catches this per-system).
      if (!pathAlreadyExisted &&
          !mkdirsOk &&
          SystemPathService.safNeededFor(effectivePath) &&
          !effectivePath.startsWith('content://')) {
        throw MissingSyncFolderException(systemId, effectivePath);
      }

      // One-time-per-sync cleanup of dead sync_state rows: keyed by a
      // synthetic download-destination path the scanner never emits, or by a
      // stale SAF grant's tree root. Cheap (single indexed query + guarded
      // delete) and must run before diffing so `getState` lookups below never
      // see a dead row masquerading as cached state. Never touches
      // pending/failed rows or local_versions — see
      // SyncStateDatabase.cleanupDeadContentUriRows.
      try {
        final removed = await _syncStateDb.cleanupDeadContentUriRows(systemId, effectivePath);
        if (removed > 0) {
          developer.log('SYNC: Removed $removed dead sync_state row(s) for $systemId', name: 'VaultSync', level: 800);
        }
      } catch (e) {
        developer.log('⚠️ SYNC: Dead sync_state row cleanup failed', name: 'VaultSync', level: 900, error: e);
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

        var remoteFiles = <String, dynamic>{};
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

        // RetroArch: normalize anchored remote keys (`saves/x`, `states/x`)
        // down to the un-anchored key a local scan rooted directly at
        // `saves/` or `states/` produces (see
        // SyncPathResolver.normalizeRetroArchRemoteKey). Without this, a
        // system like `nds`/`gba` whose configured root is
        // `.../RetroArch/saves` never gets recognized as RetroArch by
        // getCloudRelPath (neither the systemId nor the bare local filename
        // contains "retroarch"), so its local files end up keyed by bare
        // filename while the remote listing stays keyed as `saves/x` —
        // every sync then saw two different keys for the same file and
        // re-queued the remote copy as a same-content "download" forever
        // (reproduced on-device with RetroArch DS saves: Mario Kart DS,
        // Nintendogs, WarioWare, Pokemon HeartGold, Professor Layton).
        // A RetroArch folder is shared by several systems (gba, n64, nds, ...),
        // each scanning it with its own save extensions, but the remote listing
        // for the RetroArch namespace was not filtered. A file another system
        // owns (a .dsv under a gba-configured RetroArch root) therefore looked
        // remote-only and was re-downloaded over the existing local file on
        // every sync. Apply the scanner's own rule to the remote keys; in this
        // namespace the cloud-relative path is the local relative path.
        if (actualPrefix == 'retroarch') {
          final allowed = (saveExtensions == null || saveExtensions.isEmpty) ? null : saveExtensions.toSet();
          final before = remoteFiles.length;
          remoteFiles = Map<String, dynamic>.fromEntries(remoteFiles.entries.where((e) =>
              DartFileScanner.shouldSyncFile(systemId.toLowerCase(), e.key, p.basename(e.key), saveExtensions: allowed)));
          if (remoteFiles.length != before) {
            developer.log('SYNC: $systemId ignores ${before - remoteFiles.length} RetroArch file(s) outside its save extensions', name: 'VaultSync', level: 800);
          }
        }
        if (actualPrefix == 'retroarch') {
          final rootAnchor = SyncPathResolver.retroArchRootAnchor(effectivePath);
          final localScanHasAnchor = SyncPathResolver.retroArchScanHasAnchor(localList);
          if (rootAnchor != null && !localScanHasAnchor) {
            final normalized = <String, dynamic>{};
            for (final entry in remoteFiles.entries) {
              final key = SyncPathResolver.normalizeRetroArchRemoteKey(
                entry.key,
                rootAnchor: rootAnchor,
                localScanHasAnchor: localScanHasAnchor,
              );
              if (normalized.containsKey(key)) {
                developer.log(
                    'SYNC: $systemId — remote "${entry.key}" normalizes to already-seen '
                    'key "$key"; keeping the first and ignoring the duplicate',
                    name: 'VaultSync',
                    level: 900);
                continue;
              }
              normalized[key] = entry.value;
            }
            remoteFiles = normalized;
          }
        }

        // 3DS/Citra/Azahar: collapse a legacy doubled `saves/saves/` remote
        // key (see SyncPathResolver.getCloudRelPath's historical fallback,
        // which used to produce exactly this for a SAF root at the
        // package/files level, now fixed) back to the canonical `saves/`
        // key so any such row the server still holds compares against this
        // device's local scan instead of being treated as remote-only and
        // re-downloaded into `.../saves/saves/…` again.
        if (actualPrefix == '3ds' || actualPrefix == 'citra' || actualPrefix == 'azahar') {
          remoteFiles = SyncPathResolver.dealias3dsDoubledSavesRemoteKeys(
            remoteFiles,
            onDuplicate: (canonicalKey, aliasedKey) => developer.log(
                'SYNC: $systemId — "$aliasedKey" is a doubled saves/saves/ duplicate of '
                '"$canonicalKey"; using "$canonicalKey" and ignoring the duplicate',
                name: 'VaultSync',
                level: 900),
          );
        }

        // De-alias the `files/` namespace duplication (see
        // SyncPathResolver.dealiasFilesRootRemoteKeys) when this system's
        // effective root is itself an Android/data package's `files/`
        // directory: some device uploaded the same relative path with a
        // redundant leading `files/` segment (its root was the package dir,
        // one level up), which otherwise never matches this device's local
        // scan keys and gets re-downloaded to a nested duplicate every sync.
        if (SystemPathService.isPackageFilesDir(effectivePath)) {
          remoteFiles = SyncPathResolver.dealiasFilesRootRemoteKeys(
            remoteFiles,
            rootIsPackageFilesDir: true,
            onDuplicate: (canonicalKey, aliasedKey) => developer.log(
                'SYNC: $systemId — "$aliasedKey" is a files/-prefixed duplicate of '
                '"$canonicalKey" under this package\'s files/ root; using '
                '"$canonicalKey" and ignoring the duplicate',
                name: 'VaultSync',
                level: 900),
          );
        }

        // Prune queue rows the server can never satisfy again (its listing no
        // longer has that path — quarantined, deleted, or moved). Computed
        // from the RAW listing (before the Wii-NAND-blob filter below) so a
        // path the server still genuinely lists is never pruned out from
        // under a job that could still succeed. Never touches pending_upload
        // or synced rows, other systems, or local_versions — see
        // SyncStateDatabase.pruneStaleQueueRows.
        try {
          final currentRemotePaths =
              fileList.map((f) => f['path'] as String).toSet();
          final pruned = await _syncStateDb.pruneStaleQueueRows(systemId, currentRemotePaths);
          if (pruned > 0) {
            developer.log(
                'SYNC: Pruned $pruned stale queue row(s) for $systemId (remote file no longer listed)',
                name: 'VaultSync',
                level: 800);
          }
        } catch (e) {
          developer.log('⚠️ SYNC: pruneStaleQueueRows failed', name: 'VaultSync', level: 900, error: e);
        }

        // Wii/GC/Dolphin NAND install data and title metadata (.app/.tmd/.wad)
        // are quarantined as garbage server-side (see
        // SyncPathResolver.isWiiNandBlobCloudPath, mirroring
        // cleanup_garbage._is_wii_nand_blob) and must never be queued for
        // upload OR download: an upload just gets quarantined right back, and
        // a download 404s. Exclude them from both candidate sets before the
        // diff below ever sees them.
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
            final int remoteSize = (remoteInfo['size'] as num).toInt();

            // Never let an empty local file replace a non-empty cloud copy by
            // UPLOAD. A save that reads as 0 bytes is a failure signal, not an
            // edit: a stale SAF index listing files that no longer exist produced
            // 23 such phantoms, all of which were uploaded over their real
            // counterparts. This must NOT also block the DOWNLOAD that would
            // repair the empty local file — that used to `continue` here
            // unconditionally, which also skipped the legitimate repair download
            // and left the file empty forever (a 65536-byte cloud copy restored
            // to the server never made it back down). The forced-download branch
            // below (`emptyLocalNonEmptyRemote`) is where that repair actually
            // happens; this flag only needs to keep it out of the "Local Newer"
            // upload branch, regardless of what the timestamps say — an empty
            // file can never legitimately be newer than a real one.
            final bool emptyLocalNonEmptyRemote = localSize == 0 && remoteSize > 0;
            if (emptyLocalNonEmptyRemote) {
              developer.log(
                  'SYNC: Local $relPath is empty (0 bytes) but the cloud copy is $remoteSize bytes — '
                  'repairing via download instead of uploading the empty file over it',
                  name: 'VaultSync',
                  level: 1000);
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

            // When either side is 0 bytes, don't trust metadata: on-device, a
            // 4 KB Switch save was never uploaded over a 0-byte server copy. The
            // 0-byte scans were real empty files in a stray copy of the save tree
            // (the scan root skipped files/), not bad SAF metadata, but the lesson
            // holds: an empty file matching an empty journal entry says nothing
            // about the real save. The shortcuts below (journal + DB-cached hash match) only compare metadata/
            // journal entries against each other, never actual file content, so when
            // either side is reporting size 0 they cannot tell a real empty file from
            // bad scan metadata. Skip both shortcuts in that case and fall through to
            // hashing the real bytes.
            final bool zeroSizeInvolved = localSize == 0 || remoteSize == 0;

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

            // A rollback after a failed download restores the file's bytes but
            // can leave its mtime looking newer than the server copy (a plain
            // filesystem write always stamps "now"; SAF can't set mtime at
            // all — see DownloadManager.handleDownloadFile's rollback
            // comments). Trusting mtime alone in that case took the "Local
            // Newer" branch below and re-uploaded the OLD, rolled-back save
            // straight over the user's good server copy.
            //
            // Guard: if this row's last attempt was a DOWNLOAD that ultimately
            // failed, and the local file's content hash hasn't changed since
            // that failure, the mtime bump is an artifact of the rollback, not
            // a real edit — treat this as cloud-still-newer and retry the
            // download instead of ever uploading. If the hash HAS changed, the
            // user genuinely played again while the download kept failing, so
            // the normal mtime-based decision below is correct.
            final bool isFailedDownloadRow = cached != null &&
                cached['status'] == 'failed' &&
                cached['failed_op'] == 'download';
            final String? failureLocalHash = cached?['failure_local_hash'] as String?;
            if (isFailedDownloadRow && failureLocalHash != null && failureLocalHash == localHash) {
              developer.log(
                  'SYNC: $relPath unchanged since its last failed download (hash matches failure-time hash) — '
                  'retrying download instead of uploading the rolled-back local copy',
                  name: 'VaultSync', level: 900);
              onProgress?.call('Queueing $relPath for patching (retry after failed download)...');
              final localRelPath = (localInfo['originalRelPath'] as String?) ?? relPath;
              await _syncStateDb.upsertState(localInfo['uri'], (remoteInfo['size'] as num).toInt(), (remoteInfo['updated_at'] as num).toInt(), remoteHash, 'pending_download', systemId: systemId, remotePath: remotePath, relPath: localRelPath, blockHashes: json.encode(currentBlockHashes));
              continue;
            }

            // emptyLocalNonEmptyRemote forces this into the download branch below
            // regardless of the timestamp comparison — an empty local file must
            // never be uploaded, no matter how "new" its mtime looks (see the
            // comment where the flag is computed above).
            if (!emptyLocalNonEmptyRemote && localTsSecToCompare >= remoteTsSec) {
              onProgress?.call('Queueing $relPath for patching (Local Newer)...');
              await _syncStateDb.upsertState(localInfo['uri'], localSize, localTs, localHash, 'pending_upload', systemId: systemId, remotePath: remotePath, relPath: relPath, blockHashes: json.encode(currentBlockHashes));
            } else {
              // Never let an empty cloud copy replace a non-empty local file, the
              // mirror of the upload guard above and of the server's 409. A 0-byte
              // "newer" remote is a failure signature, not an edit: the production
              // server holds 18 such files, and a device restoring them over real
              // saves is how they spread. Leave the local file alone.
              if (remoteSize == 0 && localSize > 0) {
                developer.log(
                    'SYNC: Refusing to download empty cloud copy of $relPath over a $localSize-byte local file',
                    name: 'VaultSync',
                    level: 1000);
                onError?.call('Skipped $relPath: cloud copy is empty but the local file is not');
                continue;
              }
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
        // developer.log's output never reaches logcat on a release Android
        // build, which is how a real sync failure on-device left no trace at
        // all to diagnose from. debugPrint always goes to stdout/logcat.
        debugPrint('VaultSync ERROR [$systemId]: ${buildErrorDetail(e)}');
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


