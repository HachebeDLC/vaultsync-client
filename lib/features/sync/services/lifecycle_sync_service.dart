import 'dart:developer' as developer;
import 'dart:io';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../domain/sync_provider.dart';
import '../../../core/services/connectivity_provider.dart';
import 'sync_service.dart';

final lifecycleSyncServiceProvider = Provider<LifecycleSyncService>((ref) {
  final service = LifecycleSyncService(ref);
  ref.onDispose(() => service.dispose());
  return service;
});

class LifecycleSyncService with WidgetsBindingObserver {
  final Ref _ref;
  static const _platform = MethodChannel('com.vaultsync.app/launcher');
  final bool _wasOffline = false;

  LifecycleSyncService(this._ref) {
    WidgetsBinding.instance.addObserver(this);
    _initConnectivityListener();
  }

  void _initConnectivityListener() {
    _ref.listen<bool>(isOnlineProvider, (previous, next) {
      if (previous == false && next == true) {
        developer.log('LIFECYCLE: Device is back online. Triggering offline queue...', name: 'VaultSync', level: 800);
        _ref.read(syncServiceProvider).processOfflineQueue();
      }
    }, fireImmediately: true);
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
      if (!(prefs.getBool('auto_sync_on_exit') ?? false)) return;

      // On Linux/desktop: resumed = app regained focus (user came back from a
      // game session). No process-level detection needed — just sync.
      if (Platform.isLinux || Platform.isWindows) {
        developer.log('LIFECYCLE: App resumed on desktop. Triggering sync.', name: 'VaultSync', level: 800);
        _ref.read(syncProvider.notifier).sync();
        return;
      }

      // Android: require usage stats permission to detect which emulator closed.
      bool hasPermission = false;
      if (Platform.isAndroid) {
        hasPermission = await _platform.invokeMethod('hasUsageStatsPermission') ?? false;
      }
      if (!hasPermission) return;

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

      String? closedPackage;
      if (Platform.isAndroid) {
        closedPackage = await _platform.invokeMethod('getRecentlyClosedEmulator', {
          'packages': emulatorPackages,
        });
      }

      if (closedPackage != null) {
        developer.log('LIFECYCLE: Detected recently active emulator $closedPackage. Triggering sync.', name: 'VaultSync', level: 800);
        _ref.read(syncProvider.notifier).sync();
      }
    } catch (e) {
      developer.log('LIFECYCLE: Sync error', name: 'VaultSync', level: 1000, error: e);
    }
  }
}
