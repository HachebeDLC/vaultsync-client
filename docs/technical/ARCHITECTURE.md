# Architecture Overview

VaultSync is a cross-platform (Android, Windows, Linux) synchronization engine that uses a hybrid architecture to balance UI flexibility with native performance.

## The Hybrid Layer Model

VaultSync is split into two primary layers: the **Orchestration Layer** (Dart/Flutter) and the **Execution Layer** (Native Kotlin/C++).

### 1. Orchestration Layer (Dart)
The Dart layer manages high-level business logic, state management, and the user interface.
- **State Management**: Uses `flutter_riverpod` for dependency injection and state tracking.
- **Routing**: Uses `go_router` for navigation.
- **Database**: Uses `sqflite` for tracking local sync states.
- **Networking**: Uses `http` for metadata API calls and `flutter_client_sse` for real-time update notifications.

### 2. Execution Layer (Native Plugin)
For performance-critical and platform-specific operations, VaultSync uses the `vaultsync_launcher` plugin.
- **Android**: Written in Kotlin, it handles AES encryption, high-speed file I/O, and the Shizuku bridge.
- **Desktop (Windows/Linux)**: Uses Dart's FFI (Foreign Function Interface) to call into native libraries (e.g., `libvaultsync_native.so`) for block hashing and encrypted file streaming.

## Core Components

- **`SyncRepository`**: Orchestrates the sync process, combining metadata from the server with local file scans.
- **`CryptoEngine`**: Implements hardware-accelerated AES-256-CBC.
- **`ShizukuService`**: A privileged bridge allowing the app to bypass Android 14+ storage restrictions for `/Android/data`.
- **`AutomationEngine`**: Monitors emulator processes to trigger automatic syncs upon game exit.

## Build System

- **Android**: Uses Gradle with the Flutter plugin. Native code is located in `local_plugins/vaultsync_launcher/android`.
- **Linux**: Uses CMake (`linux/CMakeLists.txt`) and includes a native sync module for performance.
- **Windows**: Follows the standard Flutter Windows build process with FFI support.
