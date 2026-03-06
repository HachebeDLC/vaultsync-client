import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:workmanager/workmanager.dart';
import '../data/sync_repository.dart';
import 'system_path_service.dart';

final syncServiceProvider = Provider<SyncService>((ref) {
  final repository = ref.watch(syncRepositoryProvider);
  final pathService = ref.watch(systemPathServiceProvider);
  return SyncService(repository, pathService);
});

class SyncService {
  final SyncRepository _repository;
  final SystemPathService _pathService;

  SyncService(this._repository, this._pathService);

  /// General manual sync for all systems
  Future<void> runSync({Function(String)? onProgress, bool Function()? isCancelled}) async {
    final paths = await _pathService.getAllSystemPaths();
    final allSystems = await _pathService.getEmulatorRepository().loadSystems();
    
    if (paths.isEmpty) {
      onProgress?.call('No paths configured.');
      return;
    }

    final Set<String> syncedRetroArchPaths = {};

    for (final entry in paths.entries) {
      if (isCancelled?.call() == true) {
        onProgress?.call('Sync Cancelled');
        return;
      }

      final systemId = entry.key;
      final configPath = entry.value;

      onProgress?.call('Syncing $systemId...');

      // Ensure SAF permission if needed
      final hasPermission = await _pathService.ensureSafPermission(configPath);
      if (!hasPermission) {
        onProgress?.call('Permission denied for $systemId. Skipping.');
        continue;
      }

      final effectivePath = await _pathService.getEffectivePath(systemId);
      final systemConfig = allSystems.where((s) => s.system.id == systemId).firstOrNull;
      final ignoredFolders = systemConfig?.system.ignoredFolders;

      // Check if it's a RetroArch path
      if (effectivePath.toLowerCase().contains('retroarch')) {
        final raPaths = await _pathService.getRetroArchPaths();
        final raSaves = raPaths['saves'] ?? effectivePath;
        final raStates = raPaths['states'];

        // Only sync the saves folder once
        if (!syncedRetroArchPaths.contains(raSaves)) {
          await _repository.syncSystem('RetroArch', raSaves, ignoredFolders: ignoredFolders, onProgress: onProgress);
          syncedRetroArchPaths.add(raSaves);
        }

        if (isCancelled?.call() == true) {
          onProgress?.call('Sync Cancelled');
          return;
        }

        // Only sync the states folder once (if different)
        if (raStates != null && !syncedRetroArchPaths.contains(raStates)) {
          await _repository.syncSystem('RetroArch', raStates, ignoredFolders: ignoredFolders, onProgress: onProgress);
          syncedRetroArchPaths.add(raStates);
        }
      } else {
        // Standalone system
        await _repository.syncSystem(systemId, effectivePath, ignoredFolders: ignoredFolders, onProgress: onProgress);
      }
    }
    
    if (isCancelled?.call() == true) {
       onProgress?.call('Sync Cancelled');
    } else {
       onProgress?.call('Sync Complete!');
    }
  }

  /// Syncs a single specific system immediately
  Future<void> syncSpecificSystem(String systemId, String localPath, {List<String>? ignoredFolders, Function(String)? onProgress}) async {
    // Ensure SAF permission if needed
    final hasPermission = await _pathService.ensureSafPermission(localPath);
    if (!hasPermission) {
      onProgress?.call('Permission denied for $systemId.');
      return;
    }

    final effectivePath = await _pathService.getEffectivePath(systemId);
    
    // Check if it's a RetroArch path
    if (effectivePath.toLowerCase().contains('retroarch')) {
      final raPaths = await _pathService.getRetroArchPaths();
      final raSaves = raPaths['saves'] ?? effectivePath;
      await _repository.syncSystem('RetroArch', raSaves, ignoredFolders: ignoredFolders, onProgress: onProgress);
    } else {
      await _repository.syncSystem(systemId, effectivePath, ignoredFolders: ignoredFolders, onProgress: onProgress);
    }
  }

  /// Original Logic: Called right before an emulator is launched to ensure saves are downloaded
  Future<void> syncGameBeforeLaunch(String systemId, String gameId, {Function(String)? onProgress}) async {
    onProgress?.call('Checking cloud saves for $gameId...');
    final basePath = await getSystemBasePath(systemId, gameId: gameId);
    if (basePath == null) return;

    final allSystems = await _pathService.getEmulatorRepository().loadSystems();
    final systemConfig = allSystems.where((s) => s.system.id == systemId).firstOrNull;
    final ignoredFolders = systemConfig?.system.ignoredFolders;

    // Checks remote changes and downloads them
    final filter = getFilterForGame(systemId, gameId);
    await _repository.syncSystem(systemId, basePath, ignoredFolders: ignoredFolders, onProgress: onProgress, filenameFilter: filter);
  }

  /// Original Logic: Called right after an emulator process stops
  Future<void> syncGameAfterClose(String systemId, String gameId, {Function(String)? onProgress}) async {
    onProgress?.call('Queueing background sync for $gameId...');
    
    await Workmanager().registerOneOffTask(
      "upload-${DateTime.now().millisecondsSinceEpoch}", 
      "uploadTask",
      inputData: {
        'systemId': systemId,
        'gameId': gameId,
      },
      constraints: Constraints(
        networkType: NetworkType.connected,
      ),
    );
    onProgress?.call('Sync task queued.');
  }

  String? getFilterForGame(String systemId, String gameId) {
    // Shared memory card systems shouldn't use game-specific filters
    final sharedSystems = {'ps2', 'dc', 'dreamcast', 'ngc', 'gc', 'dolphin'};
    if (sharedSystems.contains(systemId.toLowerCase())) {
      return null;
    }

    // Strip extension from gameId (e.g., "Pokemon.gba" -> "Pokemon")
    if (gameId.contains('.')) {
      return gameId.substring(0, gameId.lastIndexOf('.'));
    }
    return gameId;
  }

  Future<String?> getSystemBasePath(String systemId, {String? gameId}) async {
    final paths = await _pathService.getAllSystemPaths();
    var path = paths[systemId];
    
    path ??= _pathService.suggestSavePathById(systemId);
    
    if (path.toLowerCase().contains('retroarch')) {
        final raPaths = await _pathService.getRetroArchPaths();
        return raPaths['saves'];
    }

    // Surgical Switch Save Detection
    if (systemId.toLowerCase() == 'switch' && gameId != null) {
      final surgicalPath = await _pathService.getSwitchSavePathForGame(systemId, gameId);
      if (surgicalPath != null) return surgicalPath;
    }

    return path;
  }

  Future<List<Map<String, dynamic>>> getConflicts() async {
    return await _repository.getAllRemoteConflicts();
  }

  Future<void> resolveConflict(Map<String, dynamic> conflict, bool keepLocal) async {
    final String conflictPath = conflict['path'];
    
    // Attempt to reconstruct the original path
    String originalPath = conflictPath;
    if (conflictPath.contains('.sync-conflict-')) {
       final parts = conflictPath.split('.sync-conflict-');
       final extParts = parts[1].split('.');
       if (extParts.length > 1) {
          originalPath = "${parts[0]}.${extParts.sublist(1).join('.')}";
       } else {
          originalPath = parts[0];
       }
    }

    // Identify system and local path
    final paths = await _pathService.getAllSystemPaths();
    final raPaths = await _pathService.getRetroArchPaths();
    
    String? localRoot;
    String? localRelPath;

    for (final entry in paths.entries) {
      if (originalPath.startsWith('${entry.key}/')) {
        localRoot = entry.value;
        localRelPath = originalPath.substring(entry.key.length + 1);
        break;
      }
    }

    if (localRoot == null) {
      if (originalPath.startsWith('RetroArch Saves/')) {
        localRoot = raPaths['saves'];
        localRelPath = originalPath.substring(16);
      } else if (originalPath.startsWith('RetroArch States/')) {
        localRoot = raPaths['states'];
        localRelPath = originalPath.substring(17);
      }
    }

    if (localRoot == null || localRelPath == null) {
      throw Exception('Could not resolve local path for conflict');
    }

    if (keepLocal) {
      // 1. Force upload current local file to original path
      if (localRoot.startsWith('content://')) {
         // Re-scan to find the specific SAF URI
         final localFiles = await _repository.scanLocalFiles(localRoot, 'unknown');
         if (localFiles.containsKey(localRelPath)) {
            await _repository.uploadFile(localFiles[localRelPath]!.path, originalPath, force: true);
         }
      } else {
         final file = File('$localRoot/$localRelPath');
         if (await file.exists()) {
            await _repository.uploadFile(file, originalPath, force: true);
         }
      }
    } else {
      // Keep Cloud -> Overwrite local with server's MAIN version
      await _repository.downloadFile(originalPath, localRoot, localRelPath);
    }

    // Cleanup: Delete the conflict file from server
    await _repository.deleteRemoteFile(conflictPath);
  }

  Future<void> deleteSystemCloudData(String systemId) async {
    await _repository.deleteSystemCloudData(systemId);
  }
}
