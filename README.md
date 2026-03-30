# VaultSync Client

High-performance, hardware-encrypted emulator save synchronization for Android, Windows, and Linux.

## Core Technology
- **Hybrid Architecture:** Flutter UI with a Native Kotlin Turbo-Streamer.
- **Hardware Encryption:** Native AES-256-CBC (Convergent) using the device's hardware engine.
- **Zero-RAM Engine:** Sequential 1MB fragment streaming ensures zero OOM crashes even for multi-gigabyte saves.
- **SAF & Shizuku Bridge:** High-speed access to restricted `Android/data` folders via Storage Access Framework or Shizuku.

## Features
- **Cloudflare Stealth:** Bypasses 5MB proxy limits via mandatory 1MB fragmentation.
- **Bit-Perfect Integrity:** Guaranteed data alignment via native `manualSkip` logic.
- **Zero-Knowledge:** Encryption keys are derived locally and never sent to the server.
- **Auto-Scan:** Intelligent library-first scanning for RetroArch, AetherSX2, Dolphin, and more.
- **Automation (Beta):** Detects when an emulator closes and automatically triggers a sync.

## Documentation
For more detailed information, please refer to the following guides:
- [**User Guide**](docs/USER_GUIDE.md): Initial setup, configuration, and troubleshooting.
- [**Technical Guide**](docs/TECHNICAL_GUIDE.md): Architecture overview, encryption details, and programming guide.

## Setup
1. Install Flutter SDK.
2. Run `flutter pub get`.
3. Build for your platform:
   - **Android:** `flutter build apk`
   - **Linux:** `flutter build linux`
   - **Windows:** `flutter build windows`

## Configuration
Use the in-app settings to configure your VaultSync server URL. Standardized for Cloudflare Port 8080.
---
*VaultSync v1.2 - Secure Hardware-Accelerated Sync Engine*
