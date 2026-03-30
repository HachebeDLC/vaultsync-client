# Automation and Background Services

VaultSync provides robust automation features to detect when an emulator process has been terminated and automatically trigger synchronization events.

## 1. Process Monitoring (Android)

The `AutomationEngine.kt` uses the Android `UsageStatsManager` to track process lifecycle events.

- **`hasUsageStatsPermission()`**: Checks if the app has the required `Usage Access` permission.
- **`checkAppClosure()`**: A background task that polls the `UsageStatsManager` for recently used apps.
- **`onEmulatorClosed`**: When a monitored emulator package (e.g., `xyz.aethersx2.android`) is detected as no longer being in the foreground, a platform-channel call is sent to Dart to trigger an automatic upload of that system's saves.

## 2. Background Sync (Workmanager)

VaultSync uses the `workmanager` Flutter plugin for periodic "catch-up" syncs on mobile platforms.

### Scheduled Tasks
- **`periodic-sync`**: A periodic task (every 6 hours) that executes the `SyncService` in the background.
- **`processQueue`**: A one-off task triggered when new jobs are added to the `SyncStateDatabase` while the app is in the background.

### Task Constraints
- **Network Required**: Background tasks only run when the device has an active network connection.
- **Battery Optimization**: Tasks are scheduled to run when the battery is not low to avoid unnecessary power drain.

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
