import 'dart:developer' as developer;
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final shizukuServiceProvider = Provider<ShizukuService>((ref) {
  return ShizukuService();
});

class ShizukuStatus {
  final bool isRunning;
  final bool isAuthorized;
  final int version;
  final String? error;

  ShizukuStatus({
    required this.isRunning,
    required this.isAuthorized,
    this.version = 0,
    this.error,
  });

  factory ShizukuStatus.fromMap(Map<dynamic, dynamic> map) {
    return ShizukuStatus(
      isRunning: map['running'] ?? false,
      isAuthorized: map['authorized'] ?? false,
      version: map['version'] ?? 0,
      error: map['error'],
    );
  }
}

class ShizukuService {
  static const _platform = MethodChannel('com.vaultsync.app/launcher');

  Future<ShizukuStatus> getStatus() async {
    if (!Platform.isAndroid) return ShizukuStatus(isRunning: false, isAuthorized: false);
    developer.log('SHIZUKU: Requesting status from native...', name: 'VaultSync', level: 800);
    try {
      final Map<dynamic, dynamic> result = await _platform.invokeMethod('checkShizukuStatus');
      final status = ShizukuStatus.fromMap(result);
      developer.log('SHIZUKU: Status running=${status.isRunning}, auth=${status.isAuthorized}', name: 'VaultSync', level: 800);
      return status;
    } catch (e) {
      // Catches both PlatformException and MissingPluginException (FlutterError)
      developer.log('SHIZUKU ERROR', name: 'VaultSync', level: 1000, error: e);
      return ShizukuStatus(isRunning: false, isAuthorized: false);
    }
  }

  Future<bool> requestPermission() async {
    if (!Platform.isAndroid) return false;
    developer.log('SHIZUKU: Requesting permission...', name: 'VaultSync', level: 800);
    try {
      final bool result = await _platform.invokeMethod('requestShizukuPermission');
      developer.log('SHIZUKU: Permission result: $result', name: 'VaultSync', level: 800);
      return result;
    } on PlatformException catch (e) {
      developer.log('SHIZUKU ERROR: ${e.message}', name: 'VaultSync', level: 1000);
      return false;
    }
  }

  Future<void> openApp() async {
    if (!Platform.isAndroid) return;
    try {
      await _platform.invokeMethod('openShizukuApp');
    } catch (e) {
      developer.log('SHIZUKU: Could not open app', name: 'VaultSync', level: 900, error: e);
    }
  }

  Future<int> getAndroidVersion() async {
    if (!Platform.isAndroid) return 0;
    try {
      return await _platform.invokeMethod<int>('getAndroidVersion') ?? 0;
    } catch (_) {
      return 0;
    }
  }
}
