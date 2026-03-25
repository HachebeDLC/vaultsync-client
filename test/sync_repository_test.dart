import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vaultsync_client/features/sync/data/sync_repository.dart';
import 'package:vaultsync_client/features/sync/services/system_path_service.dart';
import 'package:vaultsync_client/features/sync/data/file_cache.dart';
import 'package:vaultsync_client/core/services/api_client.dart';
import 'package:vaultsync_client/features/sync/services/sync_network_service.dart';
import 'package:vaultsync_client/features/sync/services/sync_path_resolver.dart';
import 'package:vaultsync_client/features/sync/data/sync_state_database.dart';
import 'package:vaultsync_client/features/sync/services/file_hash_service.dart';
import 'package:vaultsync_client/features/sync/services/conflict_resolver.dart';

class MockApiClient extends Mock implements ApiClient {}
class MockSystemPathService extends Mock implements SystemPathService {}
class MockFileCache extends Mock implements FileCache {}
class MockSyncNetworkService extends Mock implements SyncNetworkService {}
class MockSyncPathResolver extends Mock implements SyncPathResolver {}
class MockSyncStateDatabase extends Mock implements SyncStateDatabase {}
class MockFileHashService extends Mock implements FileHashService {}
class MockConflictResolver extends Mock implements ConflictResolver {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});
  late SyncRepository repository;
  late MockApiClient mockApiClient;
  late MockSystemPathService mockPathService;
  late MockFileCache mockFileCache;
  late MockSyncNetworkService mockNetworkService;
  late MockSyncPathResolver mockPathResolver;
  late MockSyncStateDatabase mockSyncStateDb;
  late MockFileHashService mockFileHashService;
  late MockConflictResolver mockConflictResolver;

  setUp(() {
    mockApiClient = MockApiClient();
    mockPathService = MockSystemPathService();
    mockFileCache = MockFileCache();
    mockNetworkService = MockSyncNetworkService();
    mockPathResolver = MockSyncPathResolver();
    mockSyncStateDb = MockSyncStateDatabase();
    mockFileHashService = MockFileHashService();
    mockConflictResolver = MockConflictResolver();
    repository = SyncRepository(
      mockApiClient, 
      mockPathService, 
      mockFileCache, 
      mockNetworkService, 
      mockPathResolver, 
      mockSyncStateDb,
      mockFileHashService,
      mockConflictResolver,
    );
  });

  group('SyncRepository Error Handling', () {
    test('syncSystem should call onError when API fails', () async {
      when(() => mockPathService.getEffectivePath(any())).thenAnswer((_) async => '/test/path');
      when(() => mockApiClient.get('/api/v1/files', queryParams: any(named: 'queryParams')))
          .thenThrow(Exception('Network error'));

      String? lastError;
      try {
        await repository.syncSystem(
          'ps2', 
          '/storage/emulated/0/PS2',
          onError: (e) => lastError = e,
        );
      } catch (_) {}
      
      expect(lastError, contains('Network error'));
    });
  });
}
