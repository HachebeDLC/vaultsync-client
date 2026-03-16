import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import '../data/sync_repository.dart';
import '../domain/sync_log_provider.dart';
import 'system_path_service.dart';

final syncServiceProvider = Provider<SyncService>((ref) {
  final repository = ref.watch(syncRepositoryProvider);
  final pathService = ref.watch(systemPathServiceProvider);
  return SyncService(repository, pathService, ref);
});

class SyncService {
  final SyncRepository _repository;
  final SystemPathService _pathService;
  final ProviderRef _ref;
  final _notifications = FlutterLocalNotificationsPlugin();
  static const _platform = MethodChannel('com.vaultsync.app/launcher');

  SyncService(this._repository, this._pathService, this._ref) {
    _initNotifications();
  }

  Future<void> _initNotifications() async {
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    await _notifications.initialize(const InitializationSettings(android: android));
  }

  Future<void> _showNotification(String title, String body) async {
    const android = AndroidNotificationDetails(
      'sync_status', 'Sync Status',
      channelDescription: 'Shows progress of background save sync',
      importance: Importance.low, priority: Priority.low, showWhen: false, onlyAlertOnce: true,
    );
    await _notifications.show(999, title, body, const NotificationDetails(android: android));
  }

  Future<void> _clearNotification() async { await _notifications.cancel(999); }

  /// Runs a full synchronization for all configured systems.
  Future<void> runSync({Function(String)? onProgress, Function(String)? onError, bool Function()? isCancelled, bool fastSync = false, bool isBackground = false}) async {
    if (isBackground) {
      await _showNotification('VaultSync', 'Performing background maintenance...');
      await _platform.invokeMethod('acquirePowerLock');
    }
    
    try {
      final paths = await _pathService.getAllSystemPaths();
      final allSystems = await _pathService.getEmulatorRepository().loadSystems();
      if (paths.isEmpty) { 
        onProgress?.call('No paths configured.'); 
        return; 
      }
      
      final Set<String> syncedPaths = {};
      
      for (final entry in paths.entries) {
        if (isCancelled?.call() == true) { 
          onProgress?.call('Sync Cancelled'); 
          return; 
        }
        final systemId = entry.key;
        if (isBackground) await _showNotification('VaultSync', 'Syncing $systemId...');
        onProgress?.call('Syncing $systemId...');
        
        final systemConfig = allSystems.where((s) => s.system.id == systemId).firstOrNull;
        final ignoredFolders = systemConfig?.system.ignoredFolders;
        
        final effectivePaths = await _resolveEffectivePaths(systemId);
        
        for (final path in effectivePaths) {
          if (syncedPaths.contains(path)) continue;
          
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
            fastSync: fastSync
          );
          syncedPaths.add(path);
        }
        _ref.read(syncLogProvider.notifier).addLog(systemId, 'Synchronized');
      }
      onProgress?.call('Sync Complete!');
    } catch(e) {
      _ref.read(syncLogProvider.notifier).addLog('All', 'Sync Failed: $e', isError: true);
      onError?.call('Sync failed: $e');
    } finally { 
      if (isBackground) {
        await _clearNotification();
        await _platform.invokeMethod('releasePowerLock');
      }
    }
  }

  /// Synchronizes a specific system path.
  Future<void> syncSpecificSystem(String systemId, String localPath, {List<String>? ignoredFolders, Function(String)? onProgress, Function(String)? onError, bool fastSync = false, bool isBackground = false}) async {
    if (isBackground) {
      await _showNotification('VaultSync', 'Syncing $systemId...');
      await _platform.invokeMethod('acquirePowerLock');
    }
    try {
      final effectivePaths = await _resolveEffectivePaths(systemId);
      for (final path in effectivePaths) {
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
      _ref.read(syncLogProvider.notifier).addLog(systemId, 'Auto-Sync Success');
    } catch(e) {
      _ref.read(syncLogProvider.notifier).addLog(systemId, 'Auto-Sync Failed: $e', isError: true);
      onError?.call('Auto-sync failed: $e');
    } finally { 
      if (isBackground) {
        await _clearNotification();
        await _platform.invokeMethod('releasePowerLock');
      }
    }
  }

  /// Resolves the effective local save path(s) for [systemId].
  /// Returns multiple paths for RetroArch (saves + states directories).
  Future<List<String>> _resolveEffectivePaths(String systemId) async {
    final effectivePath = await _pathService.getEffectivePath(systemId);
    if (effectivePath.toLowerCase().contains('retroarch')) {
      final raPaths = await _pathService.getRetroArchPaths();
      final List<String> paths = [];
      if (raPaths['saves'] != null) paths.add(raPaths['saves']!);
      if (raPaths['states'] != null) paths.add(raPaths['states']!);
      // Fallback if both null (unlikely but safe)
      if (paths.isEmpty) paths.add(effectivePath);
      return paths;
    }
    return [effectivePath];
  }

  /// Synchronizes cloud saves for a specific game before launching the emulator.
  Future<void> syncGameBeforeLaunch(String systemId, String gameId, {Function(String)? onProgress, Function(String)? onError}) async {
    onProgress?.call('Checking cloud saves for $gameId...');
    final basePath = await getSystemBasePath(systemId, gameId: gameId);
    if (basePath == null) return;
    final allSystems = await _pathService.getEmulatorRepository().loadSystems();
    final systemConfig = allSystems.where((s) => s.system.id == systemId).firstOrNull;
    final filter = getFilterForGame(systemId, gameId);
    final cloudId = (systemId.toLowerCase() == 'switch') ? 'switch' : systemId;
    await _repository.syncSystem(cloudId, basePath, ignoredFolders: systemConfig?.system.ignoredFolders, onProgress: onProgress, onError: onError, filenameFilter: filter);
  }

  /// Registers a one-off background task to upload saves after an emulator is closed.
  Future<void> syncGameAfterClose(String systemId, String gameId) async {
    await Workmanager().registerOneOffTask(
      "upload-${DateTime.now().millisecondsSinceEpoch}", 
      "uploadTask",
      inputData: {'systemId': systemId, 'gameId': gameId},
      constraints: Constraints(networkType: NetworkType.connected),
    );
  }

  /// Returns a filename filter for a specific game, used to narrow down sync scope.
  String? getFilterForGame(String systemId, String gameId) {
    if ({'ps2', 'dc', 'dreamcast', 'ngc', 'gc', 'dolphin'}.contains(systemId.toLowerCase())) return null;
    return gameId.contains('.') ? gameId.substring(0, gameId.lastIndexOf('.')) : gameId;
  }

  /// Returns the base directory where saves for [systemId] are located.
  Future<String?> getSystemBasePath(String systemId, {String? gameId}) async {
    if (systemId.toLowerCase() == 'switch' && gameId != null) {
      return await _pathService.getSwitchSavePathForGame(systemId, gameId);
    }
    final effectivePaths = await _resolveEffectivePaths(systemId);
    return effectivePaths.isNotEmpty ? effectivePaths.first : null;
  }

  /// Fetches all active sync conflicts from the repository.
  Future<List<Map<String, dynamic>>> getConflicts() async => await _repository.getAllRemoteConflicts();

  /// Resolves a sync conflict by either keeping the local version or downloading the remote one.
  Future<void> resolveConflict(Map<String, dynamic> conflict, bool keepLocal) async {
    final String conflictPath = conflict['path'];
    final info = await _parseConflictInfo(conflictPath);
    
    if (info == null) { 
      await _repository.deleteRemoteFile(conflictPath); 
      return; 
    }

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
      await _repository.downloadFile(originalPath, localRoot, localRelPath, systemId: systemId, prefs: prefs); 
    }
    await _repository.deleteRemoteFile(conflictPath);
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

/// Parsed representation of a sync conflict path.
/// Holds the resolved system, roots, and canonical path for use in conflict resolution.
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
