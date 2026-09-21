import 'dart:developer' as developer;
import 'dart:io';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../domain/sync_provider.dart';
import '../../../core/services/connectivity_provider.dart';
import 'background_sync_service.dart';
import 'sync_service.dart';

final lifecycleSyncServiceProvider = Provider<LifecycleSyncService>((ref) {
  final service = LifecycleSyncService(ref);
  ref.onDispose(() => service.dispose());
  return service;
});

class LifecycleSyncService with WidgetsBindingObserver {
  final Ref _ref;

  LifecycleSyncService(this._ref) {
    WidgetsBinding.instance.addObserver(this);
    _initConnectivityListener();
  }

  void _initConnectivityListener() {
    _ref.listen<bool>(isOnlineProvider, (previous, next) {
      if (previous == false && next == true) {
        developer.log(
            'LIFECYCLE: Device is back online. Triggering offline queue...',
            name: 'VaultSync',
            level: 800);
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
        developer.log('LIFECYCLE: App resumed on desktop. Triggering sync.',
            name: 'VaultSync', level: 800);
        _ref.read(syncProvider.notifier).sync();
        return;
      }

      // Android: the app process may have been dead for anything from
      // seconds to hours (low-memory killer), so instead of the old 5-minute
      // getRecentlyClosedEmulator window, catch up from the last checkpoint
      // via usage-stats history. This also covers the case where the app
      // simply resumed normally.
      if (Platform.isAndroid) {
        final handled =
            await _ref.read(backgroundSyncServiceProvider).catchUpMissedExits();
        developer.log(
          'LIFECYCLE: App resumed on Android. Catch-up handled $handled missed exit(s).',
          name: 'VaultSync',
          level: 800,
        );
      }
    } catch (e) {
      developer.log('LIFECYCLE: Sync error',
          name: 'VaultSync', level: 1000, error: e);
    }
  }
}
