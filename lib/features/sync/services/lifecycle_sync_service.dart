import 'dart:io';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../domain/sync_provider.dart';

final lifecycleSyncServiceProvider = Provider<LifecycleSyncService>((ref) {
  final service = LifecycleSyncService(ref);
  ref.onDispose(() => service.dispose());
  return service;
});

class LifecycleSyncService with WidgetsBindingObserver {
  final Ref _ref;
  static const _platform = MethodChannel('com.vaultsync.app/launcher');

  LifecycleSyncService(this._ref) {
    WidgetsBinding.instance.addObserver(this);
  }

  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkAndTriggerSync();
    }
  }

  Future<void> _checkAndTriggerSync() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!(prefs.getBool('intelligent_sync') ?? false)) return;

      // 1. Check if we have permission
      bool hasPermission = false;
      if (Platform.isAndroid) {
        hasPermission = await _platform.invokeMethod('hasUsageStatsPermission') ?? false;
      }
      if (!hasPermission) return;

      // 2. Define emulator packages to watch
      const emulatorPackages = [
        'com.aether.sx2', 
        'xyz.aethersx2.android', 
        'com.retroarch', 
        'com.retroarch.aarch64',
        'com.citra.emu',
        'org.citra.citra_emu',
        'org.ppsspp.ppsspp',
        'org.ppsspp.ppssppgold',
        'com.dolphin.emulator',
        'com.flycast.emulator',
        'org.yuzu.yuzu_emu',
        'org.yuzu.yuzu_emu.early_access',
        'me.magnum.melonds',
      ];

      // 3. Get recently closed emulator
      String? closedPackage;
      if (Platform.isAndroid) {
        closedPackage = await _platform.invokeMethod('getRecentlyClosedEmulator', {
          'packages': emulatorPackages,
        });
      }

      if (closedPackage != null) {
        print('Lifecycle: Detected recently active emulator $closedPackage. Triggering sync.');
        // For now, trigger a full 'fastSync' to be safe
        _ref.read(syncProvider.notifier).sync();
      }
    } catch (e) {
      print('Lifecycle Sync Error: $e');
    }
  }
}
