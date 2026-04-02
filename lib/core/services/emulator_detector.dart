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
    // 1. Handle absolute paths
    if (uniqueId.startsWith('/')) {
      return File(uniqueId).existsSync();
    }

    final lowerId = uniqueId.toLowerCase();
    
    // 2. Get possible command names or flatpak IDs for this internal uniqueId
    final candidates = _getLinuxCandidates(lowerId);
    
    for (final candidate in candidates) {
      // Check if it's a Flatpak ID (usually contains dots and starts with org/net/io)
      if (candidate.contains('.') && (candidate.startsWith('org.') || candidate.startsWith('net.') || candidate.startsWith('io.'))) {
        if (await _isFlatpakInstalled(candidate)) return true;
      }
      
      // Check if it's in the PATH
      if (await _isCommandInPath(candidate)) return true;
    }
    
    return false;
  }

  List<String> _getLinuxCandidates(String id) {
    // Strip system prefix if present (e.g. "ps2.pcsx2.desktop" -> "pcsx2.desktop")
    String baseId = id;
    if (id.contains('.')) {
      final parts = id.split('.');
      if (parts.length > 1 && !id.startsWith('org.') && !id.startsWith('net.') && !id.startsWith('io.')) {
        baseId = parts.sublist(1).join('.');
      }
    }

    // Manual mappings for Linux/Steam Deck
    final Map<String, List<String>> mappings = {
      'pcsx2.desktop': ['pcsx2', 'pcsx2-qt', 'net.pcsx2.PCSX2'],
      'citra.desktop': ['citra', 'citra-qt', 'org.citra_emu.citra'],
      'azahar': ['citra', 'citra-qt', 'org.citra_emu.citra', 'io.github.lime3ds.Lime3DS'],
      'dolphin.desktop': ['dolphin-emu', 'dolphin', 'org.DolphinEmu.dolphin-emu'],
      'ppsspp.desktop': ['PPSSPPSDL', 'ppsspp', 'org.ppsspp.PPSSPP'],
      'melonds.desktop': ['melonds', 'net.kuribo64.melonDS', 'org.melonds.melonDS'],
      'duckstation.desktop': ['duckstation', 'org.duckstation.DuckStation'],
      'yuzu.desktop': ['yuzu', 'org.yuzu_emu.yuzu'],
      'ryujinx.desktop': ['ryujinx', 'org.ryujinx.Ryujinx'],
      'ra.pcsx2': ['retroarch', 'org.libretro.RetroArch'],
      'ra.snes9x': ['retroarch', 'org.libretro.RetroArch'],
      'retroarch': ['retroarch', 'org.libretro.RetroArch'],
    };

    if (mappings.containsKey(baseId)) {
      return mappings[baseId]!;
    }
    
    // Default: try the baseId itself and a version without .desktop
    return [baseId, baseId.replaceAll('.desktop', '')];
  }

  Future<bool> _isCommandInPath(String command) async {
    try {
      final result = await Process.run('which', [command]);
      return result.exitCode == 0;
    } catch (e) {
      return false;
    }
  }

  Future<bool> _isFlatpakInstalled(String appId) async {
    // Heuristic 1: Check for user data directory (fastest)
    final home = Platform.environment['HOME'];
    if (home != null) {
      if (Directory('$home/.var/app/$appId').existsSync()) return true;
    }
    
    // Heuristic 2: Run flatpak command
    try {
      final result = await Process.run('flatpak', ['info', appId]);
      return result.exitCode == 0;
    } catch (e) {
      return false;
    }
  }
}

class WindowsEmulatorDetector implements EmulatorDetector {
  @override
  Future<bool> isEmulatorInstalled(String uniqueId) async {
    if (uniqueId.contains(':\\') || uniqueId.contains(':/')) {
      return File(uniqueId).existsSync();
    }
    return false;
  }
}

class UnsupportedPlatformDetector implements EmulatorDetector {
  @override
  Future<bool> isEmulatorInstalled(String uniqueId) => Future.value(false);
}
