# VaultSync Technical Programming Guide

Welcome to the technical documentation for VaultSync. This guide is designed for developers who want to understand the inner workings of the project, its architecture, and its synchronization logic.

## Core Technical Guides

1.  [**Architecture Overview**](technical/ARCHITECTURE.md): An overview of the hybrid Flutter/Kotlin architecture and its component layers.
2.  [**Sync Protocol & Delta-Sync Algorithm**](technical/SYNC_PROTOCOL.md): Deep dive into the delta-sync protocol, including variable block sizes (256KB/1MB) and in-place patching.
3.  [**Cryptography & Key Derivation**](technical/CRYPTOGRAPHY.md): Technical details on the zero-knowledge convergent AES-256-CBC encryption model.
4.  [**Storage Abstraction (SAF & Shizuku)**](technical/STORAGE_ABSTRACTION.md): Documentation on how VaultSync abstracts POSIX, SAF, and the Shizuku AIDL bridge.
5.  [**Database Schema & State Management**](technical/DATABASE_SCHEMA.md): Breakdown of the SQLite schema and how local sync states are persisted.
6.  [**Automation & Background Services**](technical/AUTOMATION.md): How process monitoring, background jobs (Workmanager), and foreground services work.

## Common Modification Tasks

### Adding a New Emulator
1.  Open `assets/config/path_config.json`.
2.  Add the emulator's ID and default save paths for each platform.
3.  If the emulator is Android-only, ensure its package name is added to the `standaloneDefaults`.

### Modifying Encryption Logic
The core encryption logic resides in `local_plugins/vaultsync_launcher/android/src/main/kotlin/com/vaultsync/launcher/CryptoEngine.kt`.
-   `encryptBlock`: Handles the MAGIC header, IV generation, and AES encryption.
-   `decryptBlock`: Handles the reverse process, including MAGIC validation.

## Build Instructions

### Android
1.  Ensure the Flutter SDK and Android NDK are installed.
2.  `flutter pub get`
3.  `flutter build apk --debug` (or `--release`)

### Linux/Steam Deck
VaultSync is optimized for the Steam Deck (SteamOS).
1.  `flutter build linux --release`
2.  Run `linux/install_shortcut.sh` to create a Desktop and Game Mode shortcut.

---
*VaultSync Engineering*
