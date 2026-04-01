import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:workmanager/workmanager.dart';
import '../../../core/services/api_client_provider.dart';
import '../../../core/services/api_client.dart';
import '../../auth/domain/auth_provider.dart';
import '../data/sync_repository.dart';
import '../services/sync_service.dart';

@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    print("🕒 SYNC WORKER: Executing task: $task");

    const platform = MethodChannel('com.vaultsync.app/launcher');
    
    // Check connectivity first to save battery
    try {
      final bool isOnline = await platform.invokeMethod<bool>('isOnline') ?? true;
      if (!isOnline) {
        print("🕒 SYNC WORKER: Device is offline. Skipping background sync to save battery.");
        return true;
      }
    } catch (e) {
      print("⚠️ SYNC WORKER: Could not verify connectivity: $e");
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
        print("🕒 SYNC WORKER: Server not configured. Skipping.");
        return true;
      }

      // 2. Check for auth token
      final token = await apiClient.getToken();
      
      // If we've lost our session or logged out, stop the background worker permanently
      if (token == null || token.isEmpty) {
        print("🕒 SYNC WORKER: No auth token found. User is logged out. Cancelling background tasks.");
        await Workmanager().cancelAll();
        return true; 
      }

      final syncService = container.read(syncServiceProvider);
      
      if (task == "processQueue") {
        print("🕒 SYNC WORKER: Processing sync job queue...");
        await syncService.triggerQueueProcessing();
        return true;
      } else if (task == "periodicSync") {
        print("🕒 SYNC WORKER: Starting battery-efficient periodic sync...");
        await syncService.runSync(
          fastSync: true,
          isBackground: true,
          onProgress: (msg) => print("🕒 SYNC WORKER: $msg"),
        );
        return true;
      } else {
        // Generic full sync
        await syncService.runSync(
          isBackground: true,
          onProgress: (msg) => print("🕒 SYNC WORKER: $msg"),
        );
        return true;
      }
    } catch (e) {
      print("❌ SYNC WORKER FAILED: $e");
      return false;
    } finally {
      container.dispose();
    }
  });
}
