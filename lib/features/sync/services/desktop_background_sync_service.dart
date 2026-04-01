import 'dart:async';
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
    print('🚀 DESKTOP: Starting periodic background sync (every ${interval.inMinutes}m)');
    
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
    print('🔄 DESKTOP: Triggering background sync...');
    try {
      await _ref.read(syncProvider.notifier).sync();
    } catch (e) {
      print('❌ DESKTOP: Background sync failed: $e');
    }
  }
}
