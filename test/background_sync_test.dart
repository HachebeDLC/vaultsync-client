import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:vaultsync_client/features/sync/services/background_sync_service.dart';
import 'package:vaultsync_client/features/sync/services/sync_service.dart';
import 'package:vaultsync_client/features/sync/services/system_path_service.dart';

class MockSyncService extends Mock implements SyncService {}
class MockSystemPathService extends Mock implements SystemPathService {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late BackgroundSyncService service;
  late MockSyncService mockSyncService;
  late MockSystemPathService mockPathService;

  setUp(() {
    mockSyncService = MockSyncService();
    mockPathService = MockSystemPathService();
    service = BackgroundSyncService(mockSyncService, mockPathService);
  });

  test('startMonitoring should be callable', () async {
    // This is hard to verify with MethodChannels in unit tests without a mock channel,
    // but we can at least verify the method exists and doesn't crash on non-android.
    await service.startMonitoring();
  });

  test('stopMonitoring should be callable', () async {
    await service.stopMonitoring();
  });
}
