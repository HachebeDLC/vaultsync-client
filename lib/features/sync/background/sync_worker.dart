import 'dart:developer' as developer;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:workmanager/workmanager.dart';
import '../../../core/services/api_client_provider.dart';
import '../../../core/services/api_client.dart';
import '../services/sync_service.dart';

@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    developer.log('SYNC WORKER: Executing task: $task', name: 'VaultSync', level: 800);

    const platform = MethodChannel('com.vaultsync.app/launcher');
    
    // Check connectivity first to save battery
    try {
      final bool isOnline = await platform.invokeMethod<bool>('isOnline') ?? true;
      if (!isOnline) {
        developer.log('SYNC WORKER: Device is offline. Skipping background sync to save battery.', name: 'VaultSync', level: 800);
        return true;
      }
    } catch (e) {
      developer.log('SYNC WORKER: Could not verify connectivity', name: 'VaultSync', level: 900, error: e);
    }
    
    // Initialize a lightweight container for background sync
    final container = ProviderContainer(
      overrides: [
        apiClientProvider.overrideWith((ref) => ApiClient()),
      ],
    );

    try {
      final apiClient = container.read(apiClientProvider);
      
      // 1. Check if server is configured
      if (!await apiClient.isConfigured()) {
        developer.log('SYNC WORKER: Server not configured. Skipping.', name: 'VaultSync', level: 800);
        return true;
      }

      // 2. Check for auth token
      final token = await apiClient.getToken();
      
      // If we've lost our session or logged out, stop the background worker permanently
      if (token == null || token.isEmpty) {
        developer.log('SYNC WORKER: No auth token found. User is logged out. Cancelling background tasks.', name: 'VaultSync', level: 900);
        await Workmanager().cancelAll();
        return true; 
      }

      final syncService = container.read(syncServiceProvider);
      
      if (task == "processQueue") {
        developer.log('SYNC WORKER: Processing sync job queue.', name: 'VaultSync', level: 800);
        await syncService.triggerQueueProcessing();
        return true;
      } else if (task == "periodicSync" || task == "syncTask") {
        developer.log('SYNC WORKER: Starting battery-efficient periodic sync.', name: 'VaultSync', level: 800);
        await syncService.runSync(
          fastSync: true,
          isBackground: true,
          onProgress: (msg) => developer.log('SYNC WORKER: $msg', name: 'VaultSync', level: 800),
        );
        return true;
      } else {
        // Generic full sync
        await syncService.runSync(
          isBackground: true,
          onProgress: (msg) => developer.log('SYNC WORKER: $msg', name: 'VaultSync', level: 800),
        );
        return true;
      }
    } catch (e) {
      developer.log('SYNC WORKER FAILED', name: 'VaultSync', level: 1000, error: e);
      return false;
    } finally {
      container.dispose();
    }
  });
}
