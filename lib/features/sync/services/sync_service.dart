import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import '../data/sync_repository.dart';
import '../domain/sync_log_provider.dart';
import '../domain/notification_provider.dart';
import 'system_path_service.dart';
import 'notification_service.dart';
import 'power_manager_service.dart';
import '../../../core/errors/error_mapper.dart';

final syncServiceProvider = Provider<SyncService>((ref) {
  final repository = ref.watch(syncRepositoryProvider);
  final pathService = ref.watch(systemPathServiceProvider);
  final notificationService = ref.watch(notificationServiceProvider);
  final powerManager = ref.watch(powerManagerServiceProvider);
  return SyncService(repository, pathService, notificationService, powerManager, ref);
});

class SyncService {
  final SyncRepository _repository;
  final SystemPathService _pathService;
  final NotificationService _notificationService;
  final PowerManagerService _powerManager;
  final ProviderRef? _ref;
  static const _platform = MethodChannel('com.vaultsync.app/launcher');

  SyncService(this._repository, this._pathService, this._notificationService, this._powerManager, [this._ref]);

  Future<void> triggerQueueProcessing() async {
    if (Platform.isAndroid) {
      await Workmanager().registerOneOffTask(
        "process-queue-${DateTime.now().millisecondsSinceEpoch}",
        "processQueue",
        constraints: Constraints(networkType: NetworkType.connected),
      );
    } else {
      Future.microtask(() => _repository.processManualQueue());
    }
  }

  Future<void> runSync({Function(String)? onProgress, Function(String)? onError, bool Function()? isCancelled, bool fastSync = false, bool isBackground = false}) async {
    if (isBackground) {
      await _notificationService.showSyncStatus('VaultSync', 'Performing background maintenance...');
    }
    await _powerManager.acquireSyncLock();

    try {
      final paths = await _pathService.getAllSystemPaths();
      final allSystems = await _pathService.getEmulatorRepository().loadSystems();
      if (paths.isEmpty) {
        onProgress?.call('No paths configured.');
        return;
      }

      Map? shizukuStatus;
      try { 
        shizukuStatus = await _platform.invokeMapMethod('checkShizukuStatus'); 
      } catch (e) { 
        print('⚠️ SyncService: checkShizukuStatus failed: $e'); 
      }
      final bool shizukuRunning = shizukuStatus?['running'] == true;
      final bool shizukuAuthorized = shizukuStatus?['authorized'] == true;

      final Set<String> syncedPaths = {};

      for (final entry in paths.entries) {
        if (isCancelled?.call() == true) { onProgress?.call('Sync Cancelled'); return; }
        final systemId = entry.key;
        if (isBackground) await _notificationService.showSyncStatus('VaultSync', 'Syncing $systemId...');
        onProgress?.call('Syncing $systemId...');

        final systemConfig = allSystems.where((s) => s.system.id == systemId).firstOrNull;
        final ignoredFolders = systemConfig?.system.ignoredFolders;
        final effectivePaths = await _resolveEffectivePaths(systemId);

        for (final path in effectivePaths) {
          final syncKey = '${systemId}_$path';
          if (syncedPaths.contains(syncKey)) continue;

          if (path.startsWith('shizuku://')) {
            if (!shizukuRunning || !shizukuAuthorized) {
              final reason = !shizukuRunning ? 'Shizuku not running' : 'Shizuku not authorized';
              print('⚠️ SKIPPING $systemId: $reason');
              _ref?.read(syncLogProvider.notifier).addLog(systemId, 'Skipped: $reason', isError: true);
              continue;
            }
          }

          final hasPermission = await _pathService.ensureSafPermission(path);
          if (!hasPermission) { 
            onProgress?.call('Permission denied for $path. Skipping.'); 
            onError?.call('Permission denied for $path'); 
            continue; 
          }

          await _repository.syncSystem(
            path.toLowerCase().contains('retroarch') ? 'RetroArch' : systemId, 
            path, 
            ignoredFolders: ignoredFolders, 
            onProgress: onProgress, 
            onError: onError, 
            fastSync: fastSync,
            isCancelled: isCancelled
          );
          syncedPaths.add(syncKey);
        }
        _ref?.read(syncLogProvider.notifier).addLog(systemId, 'Synchronized');
      }
      await triggerQueueProcessing();
      onProgress?.call('Sync Complete!');
    } catch(e) {
      _ref?.read(notificationLogProvider.notifier).addError(e, systemId: 'All');
      final userError = ErrorMapper.map(e);
      _ref?.read(syncLogProvider.notifier).addLog('All', userError.message, isError: true, errorTitle: userError.title);
      onError?.call(userError.toString());
    } finally {
      if (isBackground) await _notificationService.clearSyncStatus();
      await _powerManager.releaseSyncLock();
    }
  }

  Future<void> syncSpecificSystem(String systemId, String localPath, {List<String>? ignoredFolders, Function(String)? onProgress, Function(String)? onError, bool fastSync = false, bool isBackground = false}) async {
    if (isBackground) await _notificationService.showSyncStatus('VaultSync', 'Syncing $systemId...');
    await _powerManager.acquireSyncLock();
    try {
      Map? shizukuStatus;
      try { 
        shizukuStatus = await _platform.invokeMapMethod('checkShizukuStatus'); 
      } catch (e) { 
        print('⚠️ SyncService: checkShizukuStatus failed: $e'); 
      }
      final bool shizukuRunning = shizukuStatus?['running'] == true;
      final bool shizukuAuthorized = shizukuStatus?['authorized'] == true;

      final effectivePaths = await _resolveEffectivePaths(systemId);
      for (final path in effectivePaths) {
        if (path.startsWith('shizuku://') && (!shizukuRunning || !shizukuAuthorized)) {
          final reason = !shizukuRunning ? 'Shizuku not running' : 'Shizuku not authorized';
          _ref?.read(syncLogProvider.notifier).addLog(systemId, 'Skipped: $reason', isError: true);
          continue;
        }

        final hasPermission = await _pathService.ensureSafPermission(path);
        if (!hasPermission) continue;

        await _repository.syncSystem(
          path.toLowerCase().contains('retroarch') ? 'RetroArch' : systemId, 
          path, 
          ignoredFolders: ignoredFolders, 
          onProgress: onProgress, 
          onError: onError, 
          fastSync: fastSync
        );
      }
      await triggerQueueProcessing();
      _ref?.read(syncLogProvider.notifier).addLog(systemId, 'Auto-Sync Success');
    } catch(e) {
      _ref?.read(notificationLogProvider.notifier).addError(e, systemId: systemId);
      final userError = ErrorMapper.map(e);
      _ref?.read(syncLogProvider.notifier).addLog(systemId, userError.message, isError: true, errorTitle: userError.title);
      onError?.call(userError.toString());
    } finally {
      if (isBackground) await _notificationService.clearSyncStatus();
      await _powerManager.releaseSyncLock();
    }
  }

  Future<void> syncGameBeforeLaunch(String systemId, String gameId, {Function(String)? onProgress, Function(String)? onError}) async {
    final path = await _pathService.getEffectivePath(systemId);
    await _repository.syncSystem(systemId, path, filenameFilter: gameId, onProgress: onProgress, onError: onError);
  }

  Future<void> syncGameAfterClose(String systemId, String gameId) async {
    final path = await _pathService.getEffectivePath(systemId);
    await _repository.syncSystem(systemId, path, filenameFilter: gameId);
    await triggerQueueProcessing();
  }

  Future<List<Map<String, dynamic>>> getConflicts() async {
    return await _repository.getAllRemoteConflicts();
  }

  Future<List<String>> _resolveEffectivePaths(String systemId) async {
    if (systemId == 'RetroArch') {
      final paths = await _pathService.getRetroArchPaths();
      return [paths['saves']!, paths['states']!];
    }
    return [await _pathService.getEffectivePath(systemId)];
  }

  Future<void> resolveConflict(String conflictPath, bool keepLocal) async {
    try {
      final info = await _parseConflictInfo(conflictPath);
      if (info == null) return;

      final localRoot = info.localRoot;
      final localRelPath = info.localRelPath;
      final systemId = info.systemId;
      final originalPath = info.originalPath;

      final prefs = await SharedPreferences.getInstance();

      if (keepLocal) {
        if (localRoot.startsWith('content://')) {
           final files = await _repository.scanLocalFiles(localRoot, systemId);
           if (files.containsKey(localRelPath)) {
             await _repository.uploadFile(files[localRelPath]!['uri'], originalPath, systemId: systemId, relPath: localRelPath, force: true, prefs: prefs);
           }
        } else {
           final file = File('$localRoot/$localRelPath');
           if (await file.exists()) {
             await _repository.uploadFile(file, originalPath, systemId: systemId, relPath: localRelPath, force: true, prefs: prefs);
           }
        }
      } else { 
        final List<Map<String, dynamic>> versions = await _repository.getFileVersions(originalPath);
        int size = 0;
        if (versions.isNotEmpty) {
          size = versions.first['size'] ?? 0;
        }
        await _repository.downloadFile(originalPath, localRoot, localRelPath, systemId: systemId, prefs: prefs, fileSize: size); 
      }
      await _repository.deleteRemoteFile(conflictPath);
    } catch (e) {
      _ref?.read(notificationLogProvider.notifier).addError(e, systemId: 'Conflict');
      rethrow;
    }
  }

  Future<_ConflictInfo?> _parseConflictInfo(String conflictPath) async {
    String originalPath = conflictPath;
    if (conflictPath.contains('.sync-conflict-')) {
       final parts = conflictPath.split('.sync-conflict-');
       final pathBefore = parts[0]; final after = parts[1];
       final ext = after.contains('.') ? after.substring(after.lastIndexOf('.')) : '';
       originalPath = pathBefore.toLowerCase().endsWith(ext.toLowerCase()) ? pathBefore : "$pathBefore$ext";
    }

    final paths = await _pathService.getAllSystemPaths();
    String? localRoot; 
    String? localRelPath; 
    String? systemId;

    for (final entry in paths.entries) {
      final prefix = '${entry.key.toLowerCase()}/';
      if (originalPath.toLowerCase().startsWith(prefix)) { 
        systemId = entry.key; 
        localRoot = entry.value; 
        localRelPath = originalPath.substring(prefix.length); 
        break; 
      }
    }

    if (localRoot == null && originalPath.toLowerCase().startsWith('retroarch/')) {
      systemId = 'RetroArch'; 
      final rel = originalPath.substring(10);
      final raPaths = await _pathService.getRetroArchPaths();
      localRoot = (rel.toLowerCase().contains('.state') || rel.toLowerCase().endsWith('.png')) 
          ? raPaths['states'] 
          : raPaths['saves'];
      localRelPath = rel;
    }

    if (systemId == null || localRoot == null || localRelPath == null) return null;

    return _ConflictInfo(
      systemId: systemId,
      localRoot: localRoot,
      localRelPath: localRelPath,
      originalPath: originalPath,
    );
  }
}

class _ConflictInfo {
  final String systemId;
  final String localRoot;
  final String localRelPath;
  final String originalPath;

  _ConflictInfo({
    required this.systemId,
    required this.localRoot,
    required this.localRelPath,
    required this.originalPath,
  });
}
