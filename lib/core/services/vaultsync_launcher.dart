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
}
