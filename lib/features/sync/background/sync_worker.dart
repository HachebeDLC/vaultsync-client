import 'dart:io';
import '../data/sync_state_database.dart';
import '../services/sync_network_service.dart';
import '../services/sync_path_resolver.dart';
import 'package:workmanager/workmanager.dart';
import '../../../core/services/api_client.dart';
import '../../../core/services/notification_service.dart';
import '../../auth/data/auth_repository.dart';
import '../../emulation/data/emulator_repository.dart';
import '../data/file_cache.dart';
import '../data/sync_repository.dart';
import '../services/sync_service.dart';
import '../services/system_path_service.dart';

@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    print("Native called background task: $task");
    
    // Initialize notifications in background isolate
    await NotificationService.init();

    final apiClient = ApiClient();
    final authRepository = AuthRepository(apiClient);
    final fileCache = FileCache();
    await fileCache.init();
    
    final emulatorRepository = EmulatorRepository();
    final pathService = SystemPathService(emulatorRepository);
    final syncNetworkService = SyncNetworkService(apiClient);
    final syncPathResolver = SyncPathResolver();
    final syncStateDb = SyncStateDatabase();
    final syncRepository = SyncRepository(apiClient, pathService, fileCache, syncNetworkService, syncPathResolver, syncStateDb);
    final syncService = SyncService(syncRepository, pathService);

    try {
      // Background Auth Handling: Verify user is still authenticated
      final user = await authRepository.checkAuth();
      if (user == null) {
        print("Background Sync: Skipping task '$task' because user is not authenticated.");
        return Future.value(true); // Task "completed" but skipped
      }

      if (task == "uploadTask") {
        final systemId = inputData?['systemId'] as String?;
        final gameId = inputData?['gameId'] as String?;

        if (systemId != null && gameId != null) {
          final basePath = await syncService.getSystemBasePath(systemId, gameId: gameId);
          if (basePath != null) {
             final filter = syncService.getFilterForGame(systemId, gameId);
             final cloudId = syncService.getCloudId(systemId, gameId: gameId);
             
             // Background upload after game close: still use full check to be safe
             await syncRepository.syncSystem(cloudId, basePath, onProgress: (msg) {
                print("Background Upload: $msg");
             }, filenameFilter: filter);
          }
        }
      } else if (task == "processQueue") {
        print("Background: Processing sync job queue...");
        final jobs = await syncStateDb.getPendingJobs();
        for (final job in jobs) {
           final systemId = job['system_id'];
           final effectivePath = await pathService.getEffectivePath(systemId);
           // Re-use logic from SyncRepository._processJobQueue but for a single job or all of them
           await syncRepository.syncSystem(systemId, effectivePath); // This will trigger _processJobQueue
        }
      } else if (task == "periodicSync") {
        // Periodic background check: use fastSync to save battery
        print("Starting battery-efficient periodic sync...");
        await NotificationService.showSyncNotification(title: 'VaultSync', body: 'Starting background auto-sync...');
        
        await syncService.runSync(
          fastSync: true,
          onProgress: (msg) {
            print("Periodic Sync: $msg");
          }
        );

        await NotificationService.showSyncNotification(title: 'VaultSync', body: 'Background auto-sync complete.');
      } else {
        // Generic full sync
        await syncService.runSync(onProgress: (msg) {
          print("Background Sync: $msg");
        });
      }
      return Future.value(true);
    } catch (e) {
      print("Background Sync Error: $e");
      return Future.value(false);
    }
  });
}
