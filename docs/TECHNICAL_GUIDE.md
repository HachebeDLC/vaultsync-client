# VaultSync Technical Programming Guide

VaultSync is a high-performance, hybrid synchronization engine. It combines a Flutter-based UI and orchestration layer with a native Kotlin plugin (`vaultsync_launcher`) to handle hardware-accelerated cryptography, low-level filesystem access, and process monitoring.

## 1. System Architecture

### Orchestration Layer (Dart/Flutter)
- **`SyncRepository`**: The central controller. It performs metadata diffing between local files and the remote server.
- **`SyncStateDatabase`**: An SQLite-based persistent store (via `sqflite`) that tracks the synchronization status of every file, its SHA-256 hash, and its 1MB/256KB block hashes.
- **`SyncEventService`**: A Server-Sent Events (SSE) listener that provides real-time updates when other devices upload new saves.
- **`SystemPathService`**: Manages the abstraction of POSIX, SAF, and Shizuku paths.

### Native Execution Layer (Kotlin/JNI)
- **`CryptoEngine`**: Low-level AES-256-CBC implementation using `javax.crypto.Cipher`.
- **`UploadManager` / `DownloadManager`**: High-speed, sequential block processors using `FileChannel` to ensure Zero-RAM overhead.
- **`AutomationEngine`**: Polls `UsageStatsManager` to detect when a monitored emulator process has been terminated.
- **`ShizukuService`**: A privileged bridge that executes file operations as a different user (typically `shell`) to bypass Android 14+ storage restrictions.

---

## 2. The Delta-Sync Algorithm

VaultSync does not simply upload whole files. It uses a custom delta-sync protocol to minimize bandwidth.

### Variable Block Sizes
The block size is determined by the total file size to balance overhead vs. granularity:
- **Small Files (< 10MB)**: Uses **256KB** blocks.
- **Large Files (≥ 10MB)**: Uses **1MB** blocks.

### The Sync Flow
1. **Metadata Check**: Dart compares local `lastModified` and `size` with the server.
2. **Block Hashing**: If a file is modified, the native engine calculates SHA-256 hashes for every block.
3. **Deduplication Check**: Dart sends the list of block hashes to `/api/v1/blocks/check`.
4. **Partial Transfer**: The server responds with the indices of blocks it doesn't have.
5. **Sequential Patching**:
   - **Upload**: `UploadManager` only sends the "dirty" blocks.
   - **Download**: `DownloadManager` requests specific blocks and uses `RandomAccessFile` (or Shizuku's `seek`) to patch the local file in-place.

---

## 3. Cryptography (Convergent AES-256-CBC)

To enable server-side deduplication while maintaining Zero-Knowledge privacy, VaultSync uses **Convergent Encryption**.

- **Key Derivation**: The Master Key is derived from the user's password locally.
- **IV Derivation**: For every block, the Initialization Vector (IV) is the **MD5 hash of the plaintext data**.
- **Deterministic Output**: Because the IV is derived from the data itself, identical plaintext blocks always produce identical ciphertext blocks. This allows the server to deduplicate identical save data across different users without knowing the content.
- **Magic Header**: Encrypted blocks are prefixed with the 7-byte ASCII string `NEOSYNC`.

---

## 4. Android Storage Abstraction

The app uses three distinct providers for file I/O:

| Provider | Mechanism | Performance | Use Case |
|----------|-----------|-------------|----------|
| **Standard IO** | `java.io.File` | High | SD Cards, public folders. |
| **SAF** | `DocumentFile` | Low | Android 11-13 `/Android/data`. |
| **Shizuku** | `IShizukuService.aidl` | Very High | Android 14+ restricted folders. |

### The Shizuku Bridge
The bridge works by binding to a user service started via the Shizuku app. The `IShizukuService.aidl` defines the interface:
- `openFile(path, mode)`: Returns a `ParcelFileDescriptor`, allowing the app to use `FileInputStream`/`FileOutputStream` directly on restricted files.
- `listFileInfo(path)`: A batch operation that returns JSON metadata for all files in a directory, avoiding the "N+1 Binder Call" performance bottleneck of SAF.

---

## 5. Persistent State (SQLite)

The `sync_state` table is the source of truth for the local engine:

```sql
CREATE TABLE sync_state(
  path TEXT PRIMARY KEY,       -- Local URI (file://, content://, or shizuku://)
  size INTEGER,                -- File size in bytes
  last_modified INTEGER,       -- Epoch timestamp
  hash TEXT,                   -- Full file SHA-256 hash
  status TEXT,                 -- synced, pending_upload, pending_download, failed
  system_id TEXT,              -- e.g., 'ps2', 'retroarch'
  remote_path TEXT,            -- Path on the server
  rel_path TEXT,               -- Relative path within the system
  block_hashes TEXT,           -- JSON array of block SHA-256 hashes
  retry_count INTEGER DEFAULT 0
);
```

---

## 6. Development & Modification

### Adding an Emulator
Update `assets/config/path_config.json`. The `emuMap` defines the mapping between system IDs and their save subdirectories.

### Adding a Native Method
1. Define the method in `IShizukuService.aidl` (if it requires root/shell).
2. Implement it in `ShizukuService.kt`.
3. Add a case to `VaultSyncLauncherPlugin.onMethodCall`.
4. Create a wrapper in Dart within `native_sync_service.dart` or `shizuku_service.dart`.

### Build Commands
- **Clean build**: `flutter clean && flutter pub get`
- **Native APK**: `flutter build apk --split-per-abi` (Native code is compiled via Gradle/CMake).
