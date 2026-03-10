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
    try {
      final Map<dynamic, dynamic> result = await _platform.invokeMethod('checkShizukuStatus');
      return ShizukuStatus.fromMap(result);
    } on PlatformException catch (e) {
      return ShizukuStatus(isRunning: false, isAuthorized: false, error: e.message);
    }
  }

  Future<bool> requestPermission() async {
    try {
      final bool result = await _platform.invokeMethod('requestShizukuPermission');
      return result;
    } on PlatformException catch (_) {
      return false;
    }
  }
}
