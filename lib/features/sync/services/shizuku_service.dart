import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:meta/meta.dart';

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
    print('🛡️ SHIZUKU: Requesting status from native...');
    try {
      final Map<dynamic, dynamic> result = await _platform.invokeMethod('checkShizukuStatus');
      final status = ShizukuStatus.fromMap(result);
      print('🛡️ SHIZUKU: Status running=${status.isRunning}, auth=${status.isAuthorized}');
      return status;
    } on PlatformException catch (e) {
      print('🛡️ SHIZUKU ERROR: ${e.message}');
      return ShizukuStatus(isRunning: false, isAuthorized: false);
    }
  }

  Future<bool> requestPermission() async {
    if (!Platform.isAndroid) return false;
    print('🛡️ SHIZUKU: Requesting permission...');
    try {
      final bool result = await _platform.invokeMethod('requestShizukuPermission');
      print('🛡️ SHIZUKU: Permission result: $result');
      return result;
    } on PlatformException catch (e) {
      print('🛡️ SHIZUKU ERROR: ${e.message}');
      return false;
    }
  }

  Future<void> openApp() async {
    if (!Platform.isAndroid) return;
    try {
      await _platform.invokeMethod('openShizukuApp');
    } catch (e) {
      print('⚠️ SHIZUKU: Could not open app: $e');
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
