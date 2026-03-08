import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:workmanager/workmanager.dart';

final backgroundSyncServiceProvider = Provider<BackgroundSyncService>((ref) {
  return BackgroundSyncService(Workmanager());
});

class BackgroundSyncService {
  final Workmanager _workmanager;

  BackgroundSyncService(this._workmanager);

  Future<void> enableAutoSync() async {
    await _workmanager.registerPeriodicTask(
      'periodicSync',
      'periodicSync',
      frequency: const Duration(minutes: 15),
      constraints: Constraints(
        networkType: NetworkType.connected,
      ),
    );
  }

  Future<void> disableAutoSync() async {
    await _workmanager.cancelByUniqueName('periodicSync');
  }
}
