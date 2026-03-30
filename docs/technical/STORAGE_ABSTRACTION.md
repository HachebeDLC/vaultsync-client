# Storage Abstraction: SAF, Shizuku, and POSIX

VaultSync uses a unified storage abstraction to provide a consistent interface across different versions of Android and other platforms.

## 1. Storage Provider Model

The `SystemPathService` abstracts three main storage access methods:

### Standard File IO (POSIX)
- **Mechanism**: `java.io.File` on Android, `dart:io` on Desktop.
- **Performance**: Very High.
- **Use Case**: Public user folders (e.g., `/storage/emulated/0/PSP/SAVEDATA`) and standard desktop directories.

### Storage Access Framework (SAF)
- **Mechanism**: `DocumentFile` and `ContentResolver`.
- **Performance**: Low (High Binder overhead).
- **Use Case**: Required for Android 11-13 restricted `/Android/data` folders.

### Shizuku Bridge (Privileged Access)
- **Mechanism**: A custom AIDL service bound via the Shizuku app.
- **Performance**: Very High.
- **Use Case**: Recommended for Android 14+ to bypass performance and permission limitations.

## 2. The Shizuku Implementation

### AIDL Interface
The `IShizukuService.aidl` defines the communication protocol between VaultSync and the privileged `ShizukuService`:

```aidl
// Example from local_plugins/vaultsync_launcher/android/src/main/aidl/com/vaultsync/launcher/IShizukuService.aidl
interface IShizukuService {
    List<String> listFiles(String path) = 1;
    byte[] readFile(String path, long offset, int length) = 2;
    void writeFile(String path, in byte[] data, long offset) = 3;
    long getFileSize(String path) = 7;
    // ... other methods ...
    ParcelFileDescriptor openFile(String path, String mode) = 11;
    String listFileInfo(String path) = 12; // Batch metadata
}
```

### Bridge Logic
- **`ShizukuService.kt`**: Implements the AIDL methods, executing as a different user (shell) with high-level filesystem permissions.
- **`VaultSyncLauncherPlugin.kt`**: Manages the connection lifecycle to the Shizuku manager and handles permission requests.

## 3. Path Resolution Strategy

VaultSync follows a **POSIX-first** resolution strategy. The `SystemPathService` provides the effective path to use:

```dart
// Example from lib/features/sync/services/system_path_service.dart
Future<String> getEffectivePath(String systemId) async {
  final rawPath = await getSystemPath(systemId);
  final useShizuku = prefs.getBool('use_shizuku') ?? false;
  final posixPath = _convertToPosix(rawPath);

  // If Shizuku is enabled, translate POSIX to shizuku:// scheme
  if (useShizuku && posixPath.startsWith('/storage/emulated/0/')) {
    return 'shizuku://$posixPath';
  }

  return posixPath;
}
```

## 4. Platform-Specific Configurations

- **`assets/config/path_config.json`**: Contains the mapping of system IDs to their default save paths for each platform.
- **Desktop Paths**: Automatically replaces `$home` placeholders with the user's home directory.
