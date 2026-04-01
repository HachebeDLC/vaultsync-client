import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final emulatorDetectorProvider = Provider<EmulatorDetector>((ref) {
  return EmulatorDetector.getPlatformDetector();
});

abstract class EmulatorDetector {
  Future<bool> isEmulatorInstalled(String uniqueId);
  
  static EmulatorDetector getPlatformDetector() {
    if (Platform.isAndroid) {
      return AndroidEmulatorDetector();
    } else if (Platform.isLinux) {
      return LinuxEmulatorDetector();
    } else if (Platform.isWindows) {
      return WindowsEmulatorDetector();
    } else {
      return UnsupportedPlatformDetector();
    }
  }
}

class AndroidEmulatorDetector implements EmulatorDetector {
  static const _methodChannel = MethodChannel('com.vaultsync.app/launcher');

  @override
  Future<bool> isEmulatorInstalled(String uniqueId) async {
    // For Android, uniqueId is the package name (e.g. com.citra.emu)
    try {
      final bool installed = await _methodChannel.invokeMethod('isPackageInstalled', {'packageName': uniqueId});
      return installed;
    } on PlatformException catch (e) {
      print('Failed to check if emulator is installed: ${e.message}');
      return false;
    }
  }
}

class LinuxEmulatorDetector implements EmulatorDetector {
  @override
  Future<bool> isEmulatorInstalled(String uniqueId) async {
    // For Linux, we check for common executable paths or use 'which'
    // This is a simplified implementation for now.
    // In a real scenario, uniqueId might be an executable name.
    
    // Check if uniqueId is an absolute path that exists
    if (uniqueId.startsWith('/')) {
      return File(uniqueId).existsSync();
    }
    
    // Otherwise, check if it's in the PATH
    try {
      final result = await Process.run('which', [uniqueId]);
      return result.exitCode == 0;
    } catch (e) {
      return false;
    }
  }
}

class WindowsEmulatorDetector implements EmulatorDetector {
  @override
  Future<bool> isEmulatorInstalled(String uniqueId) async {
    // For Windows, check common install paths.
    // Simplified: check if path exists if it looks like one.
    if (uniqueId.contains(':\\') || uniqueId.contains(':/')) {
      return File(uniqueId).existsSync();
    }
    
    // We could check registry here, but for now we'll stick to path-based or known defaults.
    return false;
  }
}

class UnsupportedPlatformDetector implements EmulatorDetector {
  @override
  Future<bool> isEmulatorInstalled(String uniqueId) => Future.value(false);
}
