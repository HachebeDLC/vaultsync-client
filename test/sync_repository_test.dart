import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vaultsync_client/features/sync/data/sync_repository.dart';
import 'package:vaultsync_client/features/sync/data/switch_profile_resolver.dart';
import 'package:vaultsync_client/features/sync/data/sync_diff_service.dart';
import 'package:vaultsync_client/features/sync/data/sync_job_queue.dart';
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
class MockSwitchProfileResolver extends Mock implements SwitchProfileResolver {}
class MockSyncDiffService extends Mock implements SyncDiffService {}
class MockSyncJobQueue extends Mock implements SyncJobQueue {}

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
  late MockSwitchProfileResolver mockSwitchResolver;
  late MockSyncDiffService mockDiffService;
  late MockSyncJobQueue mockJobQueue;

  setUp(() {
    mockApiClient = MockApiClient();
    mockPathService = MockSystemPathService();
    mockFileCache = MockFileCache();
    mockNetworkService = MockSyncNetworkService();
    mockPathResolver = MockSyncPathResolver();
    mockSyncStateDb = MockSyncStateDatabase();
    mockFileHashService = MockFileHashService();
    mockConflictResolver = MockConflictResolver();
    mockSwitchResolver = MockSwitchProfileResolver();
    mockDiffService = MockSyncDiffService();
    mockJobQueue = MockSyncJobQueue();
    repository = SyncRepository(
      mockApiClient,
      mockPathService,
      mockFileCache,
      mockNetworkService,
      mockPathResolver,
      mockSyncStateDb,
      mockFileHashService,
      mockConflictResolver,
      mockSwitchResolver,
      mockDiffService,
      mockJobQueue,
      null, // Ref not needed in unit tests
    );
  });

  group('SyncRepository Error Handling', () {
    test('syncSystem should call onError when remote file fetch fails', () async {
      when(() => mockPathService.getEffectivePath(any())).thenAnswer((_) async => '/test/path');
      when(() => mockPathService.mkdirs(any())).thenAnswer((_) async => true);
      when(() => mockConflictResolver.processLocalFiles(any(), any())).thenReturn({});
      when(() => mockDiffService.fetchAllRemoteFiles(any()))
          .thenThrow(Exception('Network error'));

      String? lastError;
      try {
        await repository.syncSystem(
          'ps2',
          '/storage/emulated/0/PS2',
          onError: (e) => lastError = e,
        );
      } catch (e) {
        print('Caught error: $e');
      }

      expect(lastError, contains('Network error'));
    });
  });

  group('SyncJobQueue', () {
    test('delegates processManualQueue to job queue', () async {
      when(() => mockJobQueue.processManual(
        getDeviceName: any(named: 'getDeviceName'),
        recordSyncSuccess: any(named: 'recordSyncSuccess'),
        getMasterKey: any(named: 'getMasterKey'),
      )).thenAnswer((_) async {});

      await repository.processManualQueue();

      verify(() => mockJobQueue.processManual(
        getDeviceName: any(named: 'getDeviceName'),
        recordSyncSuccess: any(named: 'recordSyncSuccess'),
        getMasterKey: any(named: 'getMasterKey'),
      )).called(1);
    });
  });

  group('SyncDiffService', () {
    test('diffSystem delegates to diff service with correct effectivePath', () async {
      when(() => mockPathService.getEffectivePath('ps2')).thenAnswer((_) async => '/roms/ps2');
      when(() => mockPathService.mkdirs(any())).thenAnswer((_) async => true);
      when(() => mockDiffService.diffSystem(
        any(), any(),
        effectivePath: any(named: 'effectivePath'),
        getCachedOrNewScan: any(named: 'getCachedOrNewScan'),
        isJournaledSynced: any(named: 'isJournaledSynced'),
        recordSyncSuccess: any(named: 'recordSyncSuccess'),
        ignoredFolders: any(named: 'ignoredFolders'),
      )).thenAnswer((_) async => []);

      await repository.diffSystem('ps2', '/roms/ps2');

      verify(() => mockDiffService.diffSystem(
        'ps2', '/roms/ps2',
        effectivePath: '/roms/ps2',
        getCachedOrNewScan: any(named: 'getCachedOrNewScan'),
        isJournaledSynced: any(named: 'isJournaledSynced'),
        recordSyncSuccess: any(named: 'recordSyncSuccess'),
        ignoredFolders: null,
      )).called(1);
    });
  });
}
