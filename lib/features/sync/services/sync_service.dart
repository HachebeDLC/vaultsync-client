import 'dart:developer' as developer;
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';
import '../data/sync_repository.dart';
import '../domain/sync_log_provider.dart';
import '../domain/notification_models.dart';
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
        "processQueueTask",
        "processQueue",
        existingWorkPolicy: ExistingWorkPolicy.keep,
        constraints: Constraints(networkType: NetworkType.connected),
        backoffPolicy: BackoffPolicy.exponential,
        backoffPolicyDelay: const Duration(minutes: 1),
      );
    } else {
      Future.microtask(() => _repository.processManualQueue());
    }
  }

  /// Drains the transfer queue right here, without going through WorkManager.
  ///
  /// [triggerQueueProcessing] *schedules* a drain on Android; calling it from
  /// inside the WorkManager worker just registers another task, which is why the
  /// `processQueue` task used to be an empty loop. Anything already running in a
  /// background isolate should call this instead.
  Future<void> drainQueueNow() async {
    await _repository.processManualQueue();
  }

  Future<void> processOfflineQueue() async {
    developer.log('SYNC: Restoring offline queue to active status', name: 'VaultSync', level: 800);
    await _repository.restoreOfflineQueue();
    await triggerQueueProcessing();
  }

  Future<void> runSync({Function(String)? onProgress, Function(String)? onError, bool Function()? isCancelled, bool fastSync = false, bool isBackground = false, bool ignoreConnectivity = false}) async {
    await _notificationService.init();
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
        developer.log('SyncService: checkShizukuStatus failed', name: 'VaultSync', level: 900, error: e);
      }
      final bool shizukuRunning = shizukuStatus?['running'] == true;
      final bool shizukuAuthorized = shizukuStatus?['authorized'] == true;

      final Set<String> syncedPaths = {};
      // One failing system must not stop the rest — see the per-system
      // try/catch below. Collected so the "All" summary at the end names
      // every system that failed and why, instead of the loop aborting on
      // the first failure and (across repeated sync attempts) leaving behind
      // a pile of identical, contentless "Sync Failed" entries.
      final List<String> failedSystemSummaries = [];

      for (final entry in paths.entries) {
        if (isCancelled?.call() == true) { onProgress?.call('Sync Cancelled'); return; }
        final systemId = entry.key;
        if (isBackground) await _notificationService.showSyncStatus('VaultSync', 'Syncing $systemId...');
        onProgress?.call('Syncing $systemId...');

        try {
          final systemConfig = allSystems.where((s) => s.system.id == systemId).firstOrNull;
          final ignoredFolders = systemConfig?.system.ignoredFolders;
          final saveExtensions = systemConfig?.system.saveExtensions;
          final effectivePaths = await _resolveEffectivePaths(systemId, onError: onError);

          for (final path in effectivePaths) {
            final syncKey = '${systemId}_$path';
            if (syncedPaths.contains(syncKey)) continue;

            if (path.startsWith('shizuku://')) {
              if (!shizukuRunning || !shizukuAuthorized) {
                final reason = !shizukuRunning ? 'Shizuku not running' : 'Shizuku not authorized';
                developer.log('SKIPPING $systemId: $reason', name: 'VaultSync', level: 900);
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
              _cloudNamespaceFor(systemId, path),
              path,
              ignoredFolders: ignoredFolders,
              saveExtensions: saveExtensions,
              onProgress: onProgress,
              onError: onError,
              fastSync: fastSync,
              isCancelled: isCancelled,
              ignoreConnectivity: ignoreConnectivity
            );
            syncedPaths.add(syncKey);
          }
          _ref?.read(syncLogProvider.notifier).addLog(systemId, 'Synchronized');
        } catch (e, stack) {
          developer.log('SYNC ERROR ($systemId): $e\n$stack', name: 'VaultSync', level: 1000);
          // developer.log never reaches logcat on a release Android build —
          // this is what lets adb see a sync failure at all.
          debugPrint('VaultSync ERROR [$systemId]: ${buildErrorDetail(e)}');
          final userError = ErrorMapper.map(e);
          _ref?.read(syncLogProvider.notifier).addLog(
            systemId,
            userError.message,
            isError: true,
            errorTitle: userError.title,
            detail: buildErrorDetail(e),
          );
          failedSystemSummaries.add('$systemId: ${userError.title} — ${userError.message}');
          // A session-expired/login error is not specific to this system —
          // every other system would fail the exact same way, so there is no
          // point continuing the loop. Everything else is per-system and the
          // loop moves on to the next one.
          if (userError.action == SyncAction.login) rethrow;
        }
      }
      await triggerQueueProcessing();

      if (failedSystemSummaries.isNotEmpty) {
        final combinedMessage = failedSystemSummaries.join('; ');
        final aggregateTitle = failedSystemSummaries.length == 1
            ? '1 system failed to sync'
            : '${failedSystemSummaries.length} systems failed to sync';
        _ref?.read(notificationLogProvider.notifier).addNotification(
          title: aggregateTitle,
          message: combinedMessage,
          type: NotificationType.error,
          systemId: 'All',
        );
        _ref?.read(syncLogProvider.notifier).addLog(
          'All',
          combinedMessage,
          isError: true,
          errorTitle: aggregateTitle,
        );
        onError?.call(combinedMessage);
        onProgress?.call('Sync completed with ${failedSystemSummaries.length} error(s)');
      } else {
        onProgress?.call('Sync Complete!');
      }
    } catch(e, stack) {
      // Reached only for failures outside the per-system loop above (loading
      // the configured systems/paths, or a login-required error rethrown from
      // inside it — see the comment there).
      developer.log('SYNC ERROR (All): $e\n$stack', name: 'VaultSync', level: 1000);
      debugPrint('VaultSync ERROR [All]: ${buildErrorDetail(e)}');
      _ref?.read(notificationLogProvider.notifier).addError(e, systemId: 'All');
      final userError = ErrorMapper.map(e);
      _ref?.read(syncLogProvider.notifier).addLog('All', userError.message, isError: true, errorTitle: userError.title, detail: buildErrorDetail(e));
      onError?.call(userError.toString());
      if (userError.action == SyncAction.login) rethrow;
    } finally {
      if (isBackground) await _notificationService.clearSyncStatus();
      await _powerManager.releaseSyncLock();
    }
  }

  Future<void> syncSpecificSystem(String systemId, String localPath, {List<String>? ignoredFolders, Function(String)? onProgress, Function(String)? onError, bool fastSync = false, bool isBackground = false, bool ignoreConnectivity = false}) async {
    await _notificationService.init();
    if (isBackground) await _notificationService.showSyncStatus('VaultSync', 'Syncing $systemId...');
    await _powerManager.acquireSyncLock();
    try {
      Map? shizukuStatus;
      try { 
        shizukuStatus = await _platform.invokeMapMethod('checkShizukuStatus'); 
      } catch (e) { 
        developer.log('SyncService: checkShizukuStatus failed', name: 'VaultSync', level: 900, error: e);
      }
      final bool shizukuRunning = shizukuStatus?['running'] == true;
      final bool shizukuAuthorized = shizukuStatus?['authorized'] == true;

      // Look up the per-system save-extension allowlist so the scanner
      // can ignore files this system doesn't actually persist saves to.
      List<String>? saveExtensions;
      try {
        final allSystems = await _pathService.getEmulatorRepository().loadSystems();
        saveExtensions = allSystems
            .where((s) => s.system.id == systemId)
            .firstOrNull
            ?.system
            .saveExtensions;
      } catch (_) {}

      final effectivePaths = await _resolveEffectivePaths(systemId, onError: onError);
      for (final path in effectivePaths) {
        if (path.startsWith('shizuku://') && (!shizukuRunning || !shizukuAuthorized)) {
          final reason = !shizukuRunning ? 'Shizuku not running' : 'Shizuku not authorized';
          _ref?.read(syncLogProvider.notifier).addLog(systemId, 'Skipped: $reason', isError: true);
          continue;
        }

        final hasPermission = await _pathService.ensureSafPermission(path);
        if (!hasPermission) {
          // Match runSync's reporting. This used to be a bare `continue`, so a
          // declined folder permission vanished without a trace — and this is the
          // path taken by event-driven syncs.
          onProgress?.call('Permission denied for $path. Skipping.');
          onError?.call('Permission denied for $path');
          _ref?.read(syncLogProvider.notifier).addLog(
              systemId, 'Skipped: folder permission denied',
              isError: true);
          continue;
        }

        await _repository.syncSystem(
          _cloudNamespaceFor(systemId, path),
          path,
          ignoredFolders: ignoredFolders,
          saveExtensions: saveExtensions,
          onProgress: onProgress,
          onError: onError,
          fastSync: fastSync,
          ignoreConnectivity: ignoreConnectivity
        );
      }
      await triggerQueueProcessing();
      _ref?.read(syncLogProvider.notifier).addLog(systemId, 'Auto-Sync Success');
    } catch(e) {
      debugPrint('VaultSync ERROR [$systemId]: ${buildErrorDetail(e)}');
      _ref?.read(notificationLogProvider.notifier).addError(e, systemId: systemId);
      final userError = ErrorMapper.map(e);
      _ref?.read(syncLogProvider.notifier).addLog(systemId, userError.message, isError: true, errorTitle: userError.title, detail: buildErrorDetail(e));
      onError?.call(userError.toString());
      if (userError.action == SyncAction.login) rethrow;
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

  Future<List<Map<String, dynamic>>> diffSystem(String systemId, String localPath) async {
    return await _repository.diffSystem(systemId, localPath);
  }

  Future<List<String>> _resolveEffectivePaths(String systemId, {Function(String)? onError}) async {
    if (systemId.toLowerCase() == 'retroarch') {
      final paths = await _pathService.getRetroArchPaths();
      return [paths['saves']!, paths['states']!];
    }
    return [await _pathService.getEffectivePath(systemId, onWarning: onError)];
  }

  // Cloud namespace must be 'RetroArch' (capitalized) for either:
  //   - any system whose id is 'retroarch' (case-insensitive), or
  //   - a non-RA system whose local path happens to live inside a RetroArch
  //     saves dir (libretro-frontends sharing the same folder).
  // Without the systemId clause, a user with a custom path like
  // /storage/.../Emulators/RA/saves would split their cloud namespace.
  String _cloudNamespaceFor(String systemId, String path) {
    if (systemId.toLowerCase() == 'retroarch') return 'RetroArch';
    if (path.toLowerCase().contains('retroarch')) return 'RetroArch';
    return systemId;
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
      
      // Determine if it should go to states or saves based on the new explicit path segments
      // or fall back to extension-based routing.
      if (rel.toLowerCase().startsWith('states/')) {
        localRoot = raPaths['states'];
        localRelPath = rel.substring(7);
      } else if (rel.toLowerCase().startsWith('saves/')) {
        localRoot = raPaths['saves'];
        localRelPath = rel.substring(6);
      } else {
        // Fallback for legacy flat paths
        final isState = rel.toLowerCase().contains('.state') || 
                        rel.toLowerCase().endsWith('.png') ||
                        RegExp(r'\.s\d+$').hasMatch(rel.toLowerCase());
        localRoot = isState ? raPaths['states'] : raPaths['saves'];
        localRelPath = rel;
      }
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
