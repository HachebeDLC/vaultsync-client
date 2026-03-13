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
  Future<void> runSync({Function(String)? onProgress, Function(String)? onError, bool Function()? isCancelled, bool fastSync = false}) async {
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

      final effectivePath = await _pathService.getEffectivePath(systemId);

      // Ensure permission if needed (Shizuku paths return true immediately)
      final hasPermission = await _pathService.ensureSafPermission(effectivePath);
      if (!hasPermission) {
        onProgress?.call('Permission denied for $systemId. Skipping.');
        onError?.call('Permission denied for $systemId');
        continue;
      }

      final systemConfig = allSystems.where((s) => s.system.id == systemId).firstOrNull;
      final ignoredFolders = systemConfig?.system.ignoredFolders;

      // Check if it's a RetroArch path
      if (effectivePath.toLowerCase().contains('retroarch')) {
        final raPaths = await _pathService.getRetroArchPaths();
        final raSaves = raPaths['saves'] ?? effectivePath;
        final raStates = raPaths['states'];

        // Only sync the saves folder once
        if (!syncedRetroArchPaths.contains(raSaves)) {
          await _repository.syncSystem('RetroArch', raSaves, ignoredFolders: ignoredFolders, onProgress: onProgress, onError: onError, fastSync: fastSync);
          syncedRetroArchPaths.add(raSaves);
        }

        if (isCancelled?.call() == true) {
          onProgress?.call('Sync Cancelled');
          return;
        }

        // Only sync the states folder once (if different)
        if (raStates != null && !syncedRetroArchPaths.contains(raStates)) {
          await _repository.syncSystem('RetroArch', raStates, ignoredFolders: ignoredFolders, onProgress: onProgress, onError: onError, fastSync: fastSync);
          syncedRetroArchPaths.add(raStates);
        }
      } else {
        // Standalone system
        await _repository.syncSystem(systemId, effectivePath, ignoredFolders: ignoredFolders, onProgress: onProgress, onError: onError, fastSync: fastSync);
      }
    }
    
    if (isCancelled?.call() == true) {
       onProgress?.call('Sync Cancelled');
    } else {
       onProgress?.call('Sync Complete!');
    }
  }

  /// Syncs a single specific system immediately
  Future<void> syncSpecificSystem(String systemId, String localPath, {List<String>? ignoredFolders, Function(String)? onProgress, Function(String)? onError, bool fastSync = false}) async {
    // Ensure SAF permission if needed
    final hasPermission = await _pathService.ensureSafPermission(localPath);
    if (!hasPermission) {
      onProgress?.call('Permission denied for $systemId.');
      onError?.call('Permission denied for $systemId');
      return;
    }

    final effectivePath = await _pathService.getEffectivePath(systemId);
    
    // Check if it's a RetroArch path
    if (effectivePath.toLowerCase().contains('retroarch')) {
      final raPaths = await _pathService.getRetroArchPaths();
      final raSaves = raPaths['saves'] ?? effectivePath;
      await _repository.syncSystem('RetroArch', raSaves, ignoredFolders: ignoredFolders, onProgress: onProgress, onError: onError, fastSync: fastSync);
    } else {
      await _repository.syncSystem(systemId, effectivePath, ignoredFolders: ignoredFolders, onProgress: onProgress, onError: onError, fastSync: fastSync);
    }
  }

  /// Original Logic: Called right before an emulator is launched to ensure saves are downloaded
  Future<void> syncGameBeforeLaunch(String systemId, String gameId, {Function(String)? onProgress, Function(String)? onError}) async {
    onProgress?.call('Checking cloud saves for $gameId...');
    final basePath = await getSystemBasePath(systemId, gameId: gameId);
    if (basePath == null) {
      onError?.call('Could not determine base path for $systemId');
      return;
    }

    final allSystems = await _pathService.getEmulatorRepository().loadSystems();
    final systemConfig = allSystems.where((s) => s.system.id == systemId).firstOrNull;
    final ignoredFolders = systemConfig?.system.ignoredFolders;

    // Checks remote changes and downloads them
    final filter = getFilterForGame(systemId, gameId);
    final cloudId = getCloudId(systemId, gameId: gameId);
    
    await _repository.syncSystem(cloudId, basePath, ignoredFolders: ignoredFolders, onProgress: onProgress, onError: onError, filenameFilter: filter);
  }

  /// Helper to map local system IDs to their cloud paths, 
  /// abstracting away device-specific paths like Switch User IDs.
  String getCloudId(String systemId, {String? gameId}) {
    final lowerId = systemId.toLowerCase();
    if (lowerId == 'switch' && gameId != null) {
      // Abstract cloud path: switch/<TITLE_ID>/
      return 'switch/$gameId';
    }
    return systemId;
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
    
    // Improved originalPath reconstruction:
    // Conflict format: Path/To/File.ext.sync-conflict-YYYYMMDD-HHMMSS-Device.ext
    // OR: Path/To/File.sync-conflict-YYYYMMDD-HHMMSS-Device.ext
    String originalPath = conflictPath;
    if (conflictPath.contains('.sync-conflict-')) {
       final parts = conflictPath.split('.sync-conflict-');
       final pathBeforeConflict = parts[0]; // This usually includes the extension if it was file.ext
       final afterConflict = parts[1];
       
       final extIndex = afterConflict.lastIndexOf('.');
       final ext = extIndex != -1 ? afterConflict.substring(extIndex) : '';
       
       if (pathBeforeConflict.toLowerCase().endsWith(ext.toLowerCase())) {
          originalPath = pathBeforeConflict;
       } else {
          originalPath = "$pathBeforeConflict$ext";
       }
    }

    // Identify system and local path with robust matching
    final paths = await _pathService.getAllSystemPaths();
    final raPaths = await _pathService.getRetroArchPaths();
    
    String? localRoot;
    String? localRelPath;

    // 1. Try to match configured systems (Case-Insensitive)
    final lowerOriginal = originalPath.toLowerCase();
    for (final entry in paths.entries) {
      final prefix = '${entry.key.toLowerCase()}/';
      if (lowerOriginal.startsWith(prefix)) {
        localRoot = entry.value;
        localRelPath = originalPath.substring(prefix.length);
        break;
      }
    }

    // 2. Specialized RetroArch resolution
    // Cloud structure is flat: "RetroArch/RelPath"
    if (localRoot == null && lowerOriginal.startsWith('retroarch/')) {
      final relPath = originalPath.substring(10);
      final lowerRel = relPath.toLowerCase();
      
      // Heuristic: .state/.png usually go to states, others to saves
      if (lowerRel.contains('.state') || lowerRel.endsWith('.png')) {
        localRoot = raPaths['states'];
      } else {
        localRoot = raPaths['saves'];
      }
      localRelPath = relPath;
    }

    if (localRoot == null || localRelPath == null) {
      print('⚠️ CONFLICT CLEANUP: Path "$originalPath" does not match any local system. Deleting orphaned conflict from server.');
      await _repository.deleteRemoteFile(conflictPath);
      return;
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
