# VaultSync Client

High-performance, hardware-encrypted emulator save synchronization for Android.

## Core Technology
- **Hybrid Architecture:** Flutter UI with a Native Kotlin Turbo-Streamer.
- **Hardware Encryption:** Native AES-256-CBC (Convergent) using the device's hardware engine.
- **Zero-RAM Engine:** Sequential 1MB fragment streaming ensures zero OOM crashes even for multi-gigabyte saves.
- **SAF Automation:** Automatic Storage Access Framework permission engine for restricted `Android/data` folders.

## Features
- **Cloudflare Stealth:** Bypasses 5MB proxy limits via mandatory 1MB fragmentation.
- **Bit-Perfect Integrity:** Guaranteed data alignment via native `manualSkip` logic.
- **Zero-Knowledge:** Encryption keys are derived locally and never sent to the server.
- **Auto-Scan:** Intelligent library-first scanning for RetroArch, AetherSX2, Dolphin, and more.

## Setup
1. Install Flutter SDK.
2. Run `flutter pub get`.
3. Build the native components: `flutter build apk --debug`.

## Configuration
Use the in-app settings to configure your Apollo (VaultSync) server URL. Standardized for Cloudflare Port 8080.
