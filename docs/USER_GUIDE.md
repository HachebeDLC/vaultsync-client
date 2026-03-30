# VaultSync User Guide

VaultSync is a high-performance, hardware-encrypted solution for synchronizing your emulator saves across multiple devices. This guide will help you set up and get the most out of the app.

## Table of Contents
1. [Initial Setup](#initial-setup)
2. [Configuring Emulators](#configuring-emulators)
3. [Android Permissions (SAF & Shizuku)](#android-permissions-saf--shizuku)
4. [Automation Features](#automation-features)
5. [Conflict Resolution](#conflict-resolution)
6. [Troubleshooting](#troubleshooting)

---

## Initial Setup

When you first open VaultSync, you will be prompted to connect to your VaultSync server.

1. **Server URL:** Enter the base URL of your VaultSync server (e.g., `https://vault.yourdomain.com`). If you are using the Cloudflare-optimized setup, ensure your server is reachable on the configured port.
2. **Login/Register:** Create an account or log in to your existing one.
3. **Master Key:** During registration, a local encryption key is derived. **Keep your password safe**, as it is used to derive the keys that encrypt your data. VaultSync is zero-knowledge; the server never sees your unencrypted data or your password.

## Configuring Emulators

VaultSync can automatically detect many common emulators.

### Library Scanning
The easiest way to set up is using the **Library Scanner**:
1. Go to the **Sync** tab and tap **Scan Library**.
2. Select your main ROMs folder.
3. VaultSync will identify the systems you have and suggest the correct save paths based on standard emulator configurations.

### Manual Configuration
If an emulator isn't detected:
1. Tap the **+** button or select a system.
2. Manually browse to the folder where the emulator stores its `.srm`, `.sav`, or memory card files.
3. On Android, if the folder is inside `Android/data`, see the [Permissions](#android-permissions-saf--shizuku) section below.

## Android Permissions (SAF & Shizuku)

Android restricts access to the `Android/data` folder where many emulators (like AetherSX2, Dolphin, and Yuzu) store their data.

### Storage Access Framework (SAF)
When you select a folder in `Android/data`, VaultSync will request permission via the system file picker.
- Tap **"Use this folder"** at the bottom of the system screen.
- Tap **"Allow"** to grant VaultSync access.

### Shizuku Bridge (Recommended for Android 14+)
For significantly faster performance and to bypass some SAF limitations on Android 14, we recommend using **Shizuku**:
1. Install the [Shizuku app](https://shizuku.rikka.app/) from the Play Store.
2. Follow the instructions in the Shizuku app to start the service (usually via Wireless Debugging).
3. In VaultSync **Settings**, enable **"Use Shizuku Bridge"**.
4. Grant VaultSync the permission when prompted by Shizuku.

## Automation Features

VaultSync can handle synchronization automatically so you don't have to remember to sync manually.

- **Sync on Game Exit:** In Settings, enable this to have VaultSync detect when you close an emulator and immediately upload your latest saves.
  - *Requirement:* You must grant **Usage Access** permission when prompted.
- **Periodic Background Sync:** Performs a "catch-up" sync every 6 hours to ensure all devices are up to date.

## Conflict Resolution

If a save file was modified on two different devices before a sync occurred, VaultSync will detect a conflict.

You can choose a strategy in **Settings**:
- **Ask Every Time:** (Default) Shows a prompt allowing you to choose which version to keep.
- **Always Newest:** Automatically keeps the file with the most recent modification date.
- **Prefer Local/Cloud:** Always favors one side over the other.

## Troubleshooting

### Common Errors

| Error | Cause | Solution |
|-------|-------|----------|
| **Network Error** | Cannot reach the server. | Check your internet connection and ensure the Server URL is correct. |
| **Session Expired** | Your login token is no longer valid. | Go to Settings and Log In again. |
| **Shizuku Required** | Trying to access a restricted folder without the bridge running. | Ensure Shizuku is running and authorized in the Shizuku app. |
| **Permission Denied** | SAF permission was revoked or lost. | Go to the system settings in VaultSync and re-select the folder for that emulator. |
| **Upload/Download Failed** | Interrupted connection or server timeout. | VaultSync will retry automatically, but you can also trigger a manual sync. |

### Diagnostic Mode
If you are experiencing slow speeds or errors, go to **Settings > Run System Diagnostics**. This will test:
- Native engine health.
- Encryption speed.
- SAF/Shizuku access latency.
- Server connectivity.

---
*VaultSync v1.2 - Secure Hardware-Accelerated Sync Engine*
