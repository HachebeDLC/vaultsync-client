import 'dart:developer' as developer;
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'sync_service.dart';
import 'system_path_service.dart';

final backgroundSyncServiceProvider = Provider<BackgroundSyncService>((ref) {
  final syncService = ref.watch(syncServiceProvider);
  final pathService = ref.watch(systemPathServiceProvider);
  return BackgroundSyncService(syncService, pathService);
});

class BackgroundSyncService {
  final SyncService _syncService;
  final SystemPathService _pathService;
  static const _platform = MethodChannel('com.vaultsync.app/launcher');

  BackgroundSyncService(this._syncService, this._pathService) {
    _platform.setMethodCallHandler(_handleMethodCall);
  }

  // Canonical map of emulator package -> VaultSync system id.
  // System ids use the lowercase convention; sync_service normalizes
  // 'retroarch' case-insensitively when expanding into saves+states.
  static const Map<String, String> packageToSystem = {
    // PS2
    'xyz.aethersx2.android': 'ps2',
    'xyz.nethersx2.android': 'ps2',
    'xyz.aethersx2.custom': 'ps2',
    'xyz.aethersx2.tturnip': 'ps2',
    'com.aether.sx2': 'ps2',
    // Switch
    'org.yuzu.yuzu_emu': 'switch',
    'org.yuzu.yuzu_emu.early_access': 'switch',
    'dev.eden.eden_emulator': 'switch',
    // PS1
    'com.github.stenzek.duckstation': 'ps1',
    // GameCube / Wii
    'org.dolphinemu.dolphinemu': 'wii',
    'com.dolphin.emulator': 'wii',
    // DS
    'me.magnum.melonds': 'ds',
    // 3DS
    'org.citra.citra_emu': '3ds',
    'com.citra.emu': '3ds',
    // PSP
    'org.ppsspp.ppsspp': 'psp',
    'org.ppsspp.ppssppgold': 'psp',
    // Dreamcast
    'com.flycast.emulator': 'dreamcast',
    // RetroArch family — single 'retroarch' system covers saves + states
    'com.retroarch': 'retroarch',
    'com.retroarch.aarch64': 'retroarch',
    'com.retroarch.ra32': 'retroarch',
    'org.libretro.RetroArch': 'retroarch',
  };

  Future<void> _handleMethodCall(MethodCall call) async {
    if (call.method == 'onEmulatorClosed') {
      final String package = call.arguments;
      final systemId = packageToSystem[package];

      developer.log(
          'BACKGROUND: Emulator closed ($package). Auto-syncing $systemId...',
          name: 'VaultSync',
          level: 800);

      if (systemId != null) {
        final path = await _pathService.getEffectivePath(systemId);
        final systems =
            await _pathService.getEmulatorRepository().loadSystems();
        final config =
            systems.where((s) => s.system.id == systemId).firstOrNull;

        try {
          await _syncService.syncSpecificSystem(
            systemId,
            path,
            ignoredFolders: config?.system.ignoredFolders,
            onProgress: (msg) => developer.log('BACKGROUND: $msg',
                name: 'VaultSync', level: 800),
          );
        } catch (e) {
          developer.log('BACKGROUND SYNC FAILED',
              name: 'VaultSync', level: 1000, error: e);
        }
      }
    }
  }

  Future<void> startMonitoring(
      {Duration interval = const Duration(seconds: 15)}) async {
    if (Platform.isAndroid) {
      await _platform.invokeMethod('startMonitoring', {
        'packages': packageToSystem.keys.toList(),
        'interval': interval.inMilliseconds,
      });
    }
  }

  Future<void> stopMonitoring() async {
    if (Platform.isAndroid) {
      await _platform.invokeMethod('stopMonitoring');
    }
  }
}
