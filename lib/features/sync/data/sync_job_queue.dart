import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
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
    required void Function(SharedPreferences, String, String, String)
        recordSyncSuccess,
    required Future<String?> Function() getMasterKey,
    bool Function()? isCancelled,
  }) async {
    final jobs = await _db.getPendingJobs();
    final prefs = await SharedPreferences.getInstance();

    String? rommKey;
    if (prefs.getBool('romm_sync_enabled') ?? false) {
      rommKey = await getMasterKey();
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

      try {
        if (status == 'pending_upload') {
          onProgress
              ?.call('Uploading ${relPath?.split("/").last ?? path.split("/").last}...');
          await _networkService.uploadFile(
            path, remotePath!,
            systemId: systemId,
            relPath: relPath!,
            deviceName: await getDeviceName(),
            onRecordSuccess: (sid, rp, h) => recordSyncSuccess(prefs, sid, rp, h),
            plainHash: job['hash'],
            localBlockHashes: blockHashes,
            rommKey: rommKey,
          );
        } else if (status == 'pending_download') {

          onProgress?.call(
              'Downloading ${relPath?.split("/").last ?? path.split("/").last}...');
          final downloadResult = await _networkService.downloadFile(
            remotePath!, effectivePath, relPath!,
            systemId: systemId,
            fileSize: job['size'],
            onRecordSuccess: (sid, rp, h) => recordSyncSuccess(prefs, sid, rp, h),
            remoteHash: job['hash'],
            updatedAt: (job['last_modified'] as num?)?.toInt(),
            localUri: path,
          );

          if (downloadResult is Map) {
            await _db.upsertState(
              path,
              (downloadResult['size'] as num).toInt(),
              (downloadResult['lastModified'] as num).toInt(),
              job['hash'], 'synced',
              systemId: systemId,
              remotePath: remotePath,
              relPath: relPath,
            );
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

        await _db.updateStatus(path, 'synced');
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

  Future<void> processManual({
    required Future<String> Function() getDeviceName,
    required void Function(SharedPreferences, String, String, String)
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
