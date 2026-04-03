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

  static const Map<String, String> _packageToSystem = {
    'xyz.aethersx2.android': 'ps2',
    'xyz.nethersx2.android': 'ps2',
    'org.yuzu.yuzu_emu': 'switch',
    'dev.eden.eden_emulator': 'switch',
    'com.github.stenzek.duckstation': 'ps1',
    'org.dolphinemu.dolphinemu': 'wii',
    'me.magnum.melonds': 'ds',
  };

  Future<void> _handleMethodCall(MethodCall call) async {
    if (call.method == 'onEmulatorClosed') {
      final String package = call.arguments;
      final systemId = _packageToSystem[package];
      
      developer.log('BACKGROUND: Emulator closed ($package). Auto-syncing $systemId...', name: 'VaultSync', level: 800);
      
      if (systemId != null) {
        final path = await _pathService.getEffectivePath(systemId);
        final systems = await _pathService.getEmulatorRepository().loadSystems();
        final config = systems.where((s) => s.system.id == systemId).firstOrNull;
        
        try {
          await _syncService.syncSpecificSystem(
            systemId, 
            path, 
            ignoredFolders: config?.system.ignoredFolders,
            onProgress: (msg) => developer.log('BACKGROUND: $msg', name: 'VaultSync', level: 800),
          );
        } catch (e) {
          developer.log('BACKGROUND SYNC FAILED', name: 'VaultSync', level: 1000, error: e);
        }
      }
    }
  }

  Future<void> startMonitoring() async {
    if (Platform.isAndroid) {
      await _platform.invokeMethod('startMonitoring', {
        'packages': _packageToSystem.keys.toList(),
      });
    }
  }

  Future<void> stopMonitoring() async {
    if (Platform.isAndroid) {
      await _platform.invokeMethod('stopMonitoring');
    }
  }
}
