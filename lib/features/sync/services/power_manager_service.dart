import 'dart:io';
import 'package:flutter/services.dart';

class PowerManagerService {
  static const _platform = MethodChannel('com.vaultsync.app/launcher');

  Future<void> acquireSyncLock() async {
    if (Platform.isAndroid) {
      await _platform.invokeMethod('acquirePowerLock');
    }
  }

  Future<void> releaseSyncLock() async {
    if (Platform.isAndroid) {
      await _platform.invokeMethod('releasePowerLock');
    }
  }
}
