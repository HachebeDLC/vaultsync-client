import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../domain/sync_provider.dart';

final desktopBackgroundSyncServiceProvider = Provider<DesktopBackgroundSyncService>((ref) {
  return DesktopBackgroundSyncService(ref);
});

class DesktopBackgroundSyncService {
  final Ref _ref;
  Timer? _syncTimer;

  DesktopBackgroundSyncService(this._ref);

  void startAutoSync({Duration interval = const Duration(minutes: 15)}) {
    if (!Platform.isWindows && !Platform.isLinux) return;
    
    stopAutoSync();
    developer.log('DESKTOP: Starting periodic background sync (every ${interval.inMinutes}m)', name: 'VaultSync', level: 800);
    
    _syncTimer = Timer.periodic(interval, (timer) {
      _triggerSync();
    });
  }

  void stopAutoSync() {
    _syncTimer?.cancel();
    _syncTimer = null;
  }

  Future<void> sync() async {
    await _triggerSync();
  }

  Future<void> _triggerSync() async {
    developer.log('DESKTOP: Triggering background sync...', name: 'VaultSync', level: 800);
    try {
      await _ref.read(syncProvider.notifier).sync();
    } catch (e) {
      developer.log('DESKTOP: Background sync failed', name: 'VaultSync', level: 1000, error: e);
    }
  }
}
