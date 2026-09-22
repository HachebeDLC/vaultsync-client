import 'dart:convert';
import 'dart:developer' as developer;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'sync_state_database.dart';
import '../domain/notification_provider.dart';
import '../services/sync_network_service.dart';
import '../services/system_path_service.dart';
import '../../../core/services/api_client.dart';

/// Processes pending upload/download jobs from [SyncStateDatabase].
/// Handles retry logic: requeues failed jobs up to 3 attempts before marking permanent failure.
class SyncJobQueue {
  final SyncStateDatabase _db;
  final SyncNetworkService _networkService;
  final SystemPathService _pathService;
  final Ref? _ref;
  static const _platform = MethodChannel('com.vaultsync.app/launcher');

  SyncJobQueue(this._db, this._networkService, this._pathService, [this._ref]);

  Future<void> process(
    String systemId,
    String effectivePath,
    Function(String)? onProgress, {
    required Future<String> Function() getDeviceName,
    required void Function(SharedPreferences, String, String, String, int?)
        recordSyncSuccess,
    required Future<String?> Function() getMasterKey,
    bool Function()? isCancelled,
  }) async {
    final jobs = await _db.getPendingJobs();
    final prefs = await SharedPreferences.getInstance();

    String? rommKey;
    String? rommUrl;
    String? rommApiKey;
    if (prefs.getBool('romm_sync_enabled') ?? false) {
      rommKey = await getMasterKey();
      rommUrl = prefs.getString('romm_url');
      rommApiKey = prefs.getString('romm_api_key');
      developer.log('QUEUE: Attaching RomM Key for background sync', name: 'VaultSync', level: 800);
    }

    for (final job in jobs) {
      if (isCancelled?.call() == true) { onProgress?.call('Sync Cancelled'); break; }
      if (job['system_id'] != systemId) continue;
      final path = job['path'] as String;
      final status = job['status'] as String;
      final remotePath = job['remote_path'] as String?;
      final relPath = job['rel_path'] as String?;
      final blockHashesJson = job['block_hashes'] as String?;
      final List<String>? blockHashes = blockHashesJson != null
          ? List<String>.from(jsonDecode(blockHashesJson))
          : null;

      // Set when a completed download's state row was written under a
      // canonical URI different from the job's (synthetic) `path` and that
      // synthetic row was deleted — see the `downloadResult['uri']` handling
      // below. Guards the final `updateStatus(path, ...)` call so it doesn't
      // resurrect / no-op against a row that's intentionally gone.
      bool statePathMoved = false;

      try {
        if (status == 'pending_upload') {
          onProgress
              ?.call('Uploading ${relPath?.split("/").last ?? path.split("/").last}...');
          await _networkService.uploadFile(
            path, remotePath!,
            systemId: systemId,
            relPath: relPath!,
            deviceName: await getDeviceName(),
            onRecordSuccess: (sid, rp, h, ts) => recordSyncSuccess(prefs, sid, rp, h, ts),
            plainHash: job['hash'],
            localBlockHashes: blockHashes,
            rommKey: rommKey,
            rommUrl: rommUrl,
            rommApiKey: rommApiKey,
          );

        } else if (status == 'pending_download') {

          onProgress?.call(
              'Downloading ${relPath?.split("/").last ?? path.split("/").last}...');

          // Derive the CLOUD relative path for journaling by stripping the
          // system-prefix segment from remotePath (e.g. 'RetroArch/saves/game.srm'
          // → 'saves/game.srm').  relPath is the LOCAL write destination which may
          // differ from the cloud path on systems with path transforms (3DS, PSP,
          // Switch, …).  Using relPath as the journal key would produce a mismatch
          // on subsequent sync lookups that use the cloud path.
          final cloudRelPathForJournal = remotePath != null && remotePath.contains('/')
              ? remotePath.substring(remotePath.indexOf('/') + 1)
              : relPath;

          final downloadResult = await _networkService.downloadFile(
            remotePath!, effectivePath, relPath!,
            systemId: systemId,
            fileSize: job['size'],
            onRecordSuccess: (sid, _, h, ts) =>
                recordSyncSuccess(prefs, sid, cloudRelPathForJournal ?? '', h, ts),
            remoteHash: job['hash'],
            updatedAt: (job['last_modified'] as num?)?.toInt(),
            localUri: path,
          );

          if (downloadResult is Map) {
            final int resultSize = (downloadResult['size'] as num).toInt();
            final int resultLastModified = (downloadResult['lastModified'] as num).toInt();
            // Native now returns the canonical URI it actually wrote/resolved
            // the file under (see DownloadManager.handleDownloadFile). `path`
            // here is the synthetic `p.join(effectivePath, destRelPath)` string
            // SyncRepository queued the job under for a remote-only download —
            // not a URI the scanner can ever produce. When native hands back a
            // different, real one, move the state row there so the next sync's
            // `getState(scannedUri)` lookup actually finds it instead of
            // re-hashing (and, offline, re-snapshotting) the file forever.
            final String? canonicalUri = downloadResult['uri'] as String?;
            if (canonicalUri != null && canonicalUri != path) {
              await _db.upsertState(
                canonicalUri,
                resultSize,
                resultLastModified,
                job['hash'], 'synced',
                systemId: systemId,
                remotePath: remotePath,
                relPath: relPath,
              );
              await _db.deleteState(path);
              statePathMoved = true;
            } else {
              await _db.upsertState(
                path,
                resultSize,
                resultLastModified,
                job['hash'], 'synced',
                systemId: systemId,
                remotePath: remotePath,
                relPath: relPath,
              );
            }
          } else {
            try {
              final info =
                  await _platform.invokeMapMethod('getFileInfo', {'uri': path});
              if (info != null) {
                await _db.upsertState(
                  path,
                  (info['size'] as num).toInt(),
                  (info['lastModified'] as num).toInt(),
                  job['hash'], 'synced',
                  systemId: systemId,
                  remotePath: remotePath,
                  relPath: relPath,
                );
              }
            } catch (e) {
              developer.log('⚠️ Failed to update post-download metadata for $path', name: 'VaultSync', level: 900, error: e);
            }
          }
        }

        if (!statePathMoved) {
          await _db.updateStatus(path, 'synced');
        }
      } catch (e) {
        if (e is ApiException && (e.statusCode == 401 || e.statusCode == 403)) {
          rethrow; // Don't retry auth failures, let the UI handle logout
        }
        
        final retryCount = (job['retry_count'] as int? ?? 0) + 1;
        if (retryCount < 3) {
          developer.log('Job failed for $path (attempt $retryCount/3), will retry', name: 'VaultSync', level: 900, error: e);
          await _db.requeueJob(path, status, retryCount, error: e.toString());
        } else {
          developer.log('Job permanently failed for $path after $retryCount attempts', name: 'VaultSync', level: 1000, error: e);
          _ref?.read(notificationLogProvider.notifier).addError(e, systemId: systemId);
          await _db.updateStatus(path, 'failed', error: e.toString());
        }
      }
    }
  }

  /// Guards against overlapping drains within this isolate.
  ///
  /// [getPendingJobs] is a plain SELECT with no claim column and no row locking,
  /// so two concurrent drains read the same rows and transfer the same file
  /// twice. That never surfaced while nothing drained the queue at all; once the
  /// WorkManager worker, the SSE flush, app-resume and online-recovery are all
  /// live triggers it becomes reachable.
  ///
  /// LIMIT: this only covers one isolate. The WorkManager worker builds its own
  /// ProviderContainer (see main.dart), so it holds a different SyncJobQueue and
  /// this flag is invisible to it. Closing that gap needs a claim/lease column in
  /// `sync_state`.
  bool _draining = false;

  /// Set when a drain is requested while one is already running, so the work is
  /// retried once instead of being dropped or run concurrently.
  bool _drainRequestedAgain = false;

  Future<void> processManual({
    required Future<String> Function() getDeviceName,
    required void Function(SharedPreferences, String, String, String, int?)
        recordSyncSuccess,
    required Future<String?> Function() getMasterKey,
  }) async {
    if (_draining) {
      _drainRequestedAgain = true;
      developer.log('Queue: drain already in progress — will repeat after it finishes',
          name: 'VaultSync', level: 800);
      return;
    }
    _draining = true;
    try {
      do {
        _drainRequestedAgain = false;
        await _drainOnce(
          getDeviceName: getDeviceName,
          recordSyncSuccess: recordSyncSuccess,
          getMasterKey: getMasterKey,
        );
      } while (_drainRequestedAgain);
    } finally {
      _draining = false;
    }
  }

  Future<void> _drainOnce({
    required Future<String> Function() getDeviceName,
    required void Function(SharedPreferences, String, String, String, int?)
        recordSyncSuccess,
    required Future<String?> Function() getMasterKey,
  }) async {
    final jobs = await _db.getPendingJobs();
    final processed = <String>{};
    for (final job in jobs) {
      final systemId = job['system_id'] as String?;
      if (systemId == null || processed.contains(systemId)) continue;
      processed.add(systemId);
      final effectivePath = await _pathService.getEffectivePath(systemId);
      await process(
        systemId, effectivePath,
        (msg) => developer.log('Queue: $msg', name: 'VaultSync', level: 800),
        getDeviceName: getDeviceName,
        recordSyncSuccess: recordSyncSuccess,
        getMasterKey: getMasterKey,
      );
    }
  }
}
