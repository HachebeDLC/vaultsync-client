# Automation and Background Services

VaultSync provides robust automation features to detect when an emulator process has been terminated and automatically trigger synchronization events.

## 1. Process Monitoring (Android)

The `AutomationEngine.kt` uses the Android `UsageStatsManager` to track process lifecycle events.

#### Detection Logic (Kotlin)
The `AutomationEngine` polls the system for recently used apps and detects when a monitored package moves from the foreground to the background:

```kotlin
// Example from local_plugins/vaultsync_launcher/android/src/main/kotlin/com/vaultsync/launcher/AutomationEngine.kt
private fun checkAppClosure() {
    if (!hasUsageStatsPermission() || monitoredPackages.isEmpty()) return

    val usageStatsManager = context.getSystemService(Context.USAGE_STATS_SERVICE) as UsageStatsManager
    val time = System.currentTimeMillis()
    val stats = usageStatsManager.queryUsageStats(UsageStatsManager.INTERVAL_DAILY, time - 15000, time)

    val currentApp = stats?.filter { it.lastTimeUsed > time - 15000 }
        ?.maxByOrNull { it.lastTimeUsed }?.packageName

    if (currentApp != null && currentApp != lastForegroundApp) {
        // If the emulator was recently in foreground but isn't now
        if (monitoredPackages.contains(lastForegroundApp) && currentApp != context.packageName) {
            automationHandler.post {
                // Invoke callback to trigger the sync in Dart
                channel.invokeMethod("onEmulatorClosed", lastForegroundApp)
            }
        }
        lastForegroundApp = currentApp
    }
}
```

## 2. Background Sync (Workmanager)

VaultSync uses the `workmanager` Flutter plugin for periodic "catch-up" syncs on mobile platforms.

- **`periodic-sync`**: A periodic task (every 6 hours) that executes the `SyncService` in the background.
- **`processQueue`**: A one-off task triggered when new jobs are added to the `SyncStateDatabase` while the app is in the background.

## 3. Desktop Background Sync

On Windows and Linux, VaultSync implements background synchronization through:
- **`DesktopBackgroundSyncService.dart`**: A background loop that performs periodic syncs at a configured interval.
- **`DesktopTrayService.dart`**: A system tray icon that allows the user to see the current sync status and trigger manual syncs without opening the main window.

## 4. Foreground Services (Android)

During long-running upload or download operations, VaultSync starts a **Foreground Service** (`SyncForegroundService.kt`) with a persistent notification. This ensures:
- The Android system does not terminate the app's process during a sync.
- The user is informed about the progress of the synchronization.
- Real-time updates for multi-gigabyte files are consistently processed.

## 5. Lifecycle Management

The `LifecycleSyncService.dart` coordinates with the Flutter `AppLifecycleListener` to:
- Resume SSE connections when the app is brought to the foreground.
- Perform a "fast-sync" on startup to ensure the user has the latest saves before they start playing.
