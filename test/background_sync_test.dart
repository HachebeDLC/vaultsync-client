import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:workmanager/workmanager.dart';
import 'package:vaultsync_client/features/sync/services/background_sync_service.dart';

class MockWorkmanager extends Mock implements Workmanager {}

void main() {
  late BackgroundSyncService service;
  late MockWorkmanager mockWorkmanager;

  setUp(() {
    mockWorkmanager = MockWorkmanager();
    service = BackgroundSyncService(mockWorkmanager);
  });

  test('enableAutoSync should register periodic task', () async {
    when(() => mockWorkmanager.registerPeriodicTask(
          any(),
          any(),
          frequency: any(named: 'frequency'),
          constraints: any(named: 'constraints'),
        )).thenAnswer((_) async => Future.value());

    await service.enableAutoSync();

    verify(() => mockWorkmanager.registerPeriodicTask(
          'periodicSync',
          'periodicSync',
          frequency: const Duration(minutes: 15),
          constraints: any(named: 'constraints'),
        )).called(1);
  });

  test('disableAutoSync should cancel periodic task', () async {
    when(() => mockWorkmanager.cancelByUniqueName('periodicSync')).thenAnswer((_) async => Future.value());

    await service.disableAutoSync();

    verify(() => mockWorkmanager.cancelByUniqueName('periodicSync')).called(1);
  });
}
