import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final vaultSyncLauncherProvider = Provider((ref) => VaultSyncLauncher());

class VaultSyncLauncher {
  static const _platform = MethodChannel('com.vaultsync.app/launcher');

  Future<String?> getLocalizedString(String key) async {
    try {
      final String? result = await _platform.invokeMethod('getLocalizedString', {'key': key});
      return result;
    } on PlatformException catch (e) {
      print("Failed to get localized string: '${e.message}'.");
      return null;
    }
  }

  // Helper for common strings
  Future<String> getAppVersionFull() async {
    return await getLocalizedString('app_version_full') ?? 'v1.3.7-Secure';
  }

  Future<String> getSyncEngineDescription() async {
    return await getLocalizedString('sync_engine_description') ?? 'Hardware-Accelerated Sync Engine';
  }

  Future<void> setNativeLocale(String languageCode) async {
    try {
      await _platform.invokeMethod('setNativeLocale', {'languageCode': languageCode});
    } on PlatformException catch (e) {
      print("Failed to set native locale: '${e.message}'.");
    }
  }

  Future<bool> extractModifiedBlocks(String path, Map<int, bool> changedBlocks, String versionStorePath) async {
    try {
      final mapKeysString = changedBlocks.map((key, value) => MapEntry(key.toString(), value));
      final bool? result = await _platform.invokeMethod('extractModifiedBlocks', {
        'path': path,
        'changedBlocks': mapKeysString,
        'versionStorePath': versionStorePath,
      });
      return result ?? false;
    } on PlatformException catch (e) {
      print("Failed to extract blocks: '${e.message}'.");
      return false;
    }
  }

  Future<Map<String, dynamic>?> calculateBlockHashesAndHash(String path, {String? masterKey}) async {
    try {
      final String? result = await _platform.invokeMethod('calculateBlockHashesAndHash', {
        'path': path,
        'masterKey': masterKey,
      });
      if (result == null) return null;
      return Map<String, dynamic>.from(json.decode(result));
    } on PlatformException catch (e) {
      print("Failed to calculate hashes: '${e.message}'.");
      return null;
    }
  }

  Future<bool> reconstructFromDeltas(List<String> layoutHashes, String livePath, String restorePath, String versionStorePath) async {
    try {
      final bool? result = await _platform.invokeMethod('reconstructFromDeltas', {
        'layoutHashes': layoutHashes,
        'livePath': livePath,
        'restorePath': restorePath,
        'versionStorePath': versionStorePath,
      });
      return result ?? false;
    } on PlatformException catch (e) {
      print("Failed to reconstruct file: '${e.message}'.");
      return false;
    }
  }
}
