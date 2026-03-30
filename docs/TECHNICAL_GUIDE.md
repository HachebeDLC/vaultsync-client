# VaultSync Technical Programming Guide

VaultSync is a hybrid architecture Flutter application that uses a native Kotlin plugin for performance-critical tasks like hardware-accelerated encryption and low-level filesystem access.

## Architecture Overview

1. **Flutter UI:** Manages the user interface, routing (GoRouter), and application state (Riverpod).
2. **Sync Repository:** Orchestrates the high-level synchronization logic, including conflict detection, versioning, and journal management.
3. **VaultSync Launcher (Native Plugin):** A Kotlin-based plugin that provides:
   - **Crypto Engine:** Hardware-accelerated AES-256-CBC encryption.
   - **Fragmented Streamer:** Sequential 1MB fragment streaming for zero-RAM overhead.
   - **SAF/Shizuku Bridge:** High-speed access to restricted Android folders.
   - **Automation Engine:** Monitoring emulator process closure via `UsageStatsManager`.

---

## Technical Details

### 1. Hybrid Sync Engine
The sync process is a two-stage operation:
- **Phase 1: Metadata Diffing (Dart)** - Compares local and remote file lists.
- **Phase 2: Block-Level Synchronization (Native)** - For files larger than 1MB, VaultSync calculates SHA-256 hashes of each 1MB block. Only changed blocks are uploaded/downloaded, significantly reducing bandwidth.

### 2. Encryption (AES-256-CBC)
VaultSync uses a **Zero-Knowledge** model:
- **Master Key:** Derived locally from the user's password using PBKDF2 (on the server-side, it's stored only in salted-hash form).
- **IV Generation:** For each 1MB block, the Initialization Vector (IV) is derived from the MD5 hash of the block's data. This ensures consistent encryption for identical data (convergent encryption), enabling server-side deduplication.
- **Hardware Acceleration:** Uses the device's native `Cipher` implementation to leverage hardware engines (like Qualcomm's crypto engine).

### 3. Filesystem Abstraction (Android)
VaultSync abstracts three types of storage access:
- **Local File:** Standard `java.io.File` for unrestricted folders.
- **Storage Access Framework (SAF):** Using `DocumentFile` and `ContentResolver` for `/Android/data` access.
- **Shizuku Bridge:** A privileged bridge that uses Shizuku to perform file operations at native filesystem speeds, bypassing SAF overhead entirely.

### 4. Zero-RAM Fragmentation
To prevent Out-Of-Memory (OOM) crashes on large files (e.g., 4GB+ PS2 memory cards):
- Files are never loaded fully into memory.
- The `UploadManager` uses a `FileChannel` to read 1MB blocks sequentially.
- Each block is encrypted and sent to the server independently.
- The server reassembles them using the `x-vaultsync-offset` header.

---

## Common Modification Tasks

### Adding a New Emulator
1. Open `assets/config/path_config.json`.
2. Add the emulator's ID and default save paths for each platform.
3. If the emulator is Android-only, ensure its package name is added to the `standaloneDefaults`.

### Modifying Encryption Logic
The core encryption logic resides in `local_plugins/vaultsync_launcher/android/src/main/kotlin/com/vaultsync/launcher/CryptoEngine.kt`.
- `encryptBlock`: Handles the MAGIC header, IV generation, and AES encryption.
- `decryptBlock`: Handles the reverse process, including MAGIC validation.

### Background Task Management
VaultSync uses `Workmanager` for periodic syncs and the native `SyncForegroundService` for long-running uploads/downloads to prevent the system from killing the process.

---

## Build Instructions

### Android
1. Ensure the Flutter SDK and Android NDK are installed.
2. `flutter pub get`
3. `flutter build apk --debug` (or `--release`)

### Linux/Steam Deck
VaultSync is optimized for the Steam Deck (SteamOS).
1. `flutter build linux --release`
2. Run `linux/install_shortcut.sh` to create a Desktop and Game Mode shortcut.

---
*VaultSync Engineering*
