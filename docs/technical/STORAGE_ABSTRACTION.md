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
- `openFile(path, mode)`: Returns a `ParcelFileDescriptor`, allowing direct `FileChannel` access.
- `listFileInfo(path)`: Optimized batch metadata scan to avoid per-file Binder overhead.
- `calculateBlockHashes(path, blockSize)`: Offloads block-level hashing to the Shizuku service.

### Bridge Logic
- **`ShizukuService.kt`**: Implements the AIDL methods, executing as a different user (shell) with high-level filesystem permissions.
- **`VaultSyncLauncherPlugin.kt`**: Manages the connection lifecycle to the Shizuku manager and handles permission requests.

## 3. Path Resolution Strategy

VaultSync follows a **POSIX-first** resolution strategy:
1. Try to access the file directly via standard IO.
2. If access fails (Permission Denied), check if a SAF URI is persisted for the path.
3. If **Shizuku** is enabled in Settings, automatically translate POSIX paths to `shizuku://` prefixed paths.
4. Use the appropriate provider (Standard, SAF, or Shizuku) for all subsequent read/write operations.

## 4. Platform-Specific Configurations

- **`assets/config/path_config.json`**: Contains the mapping of system IDs to their default save paths for each platform.
- **Desktop Paths**: Automatically replaces `$home` placeholders with the user's home directory.
