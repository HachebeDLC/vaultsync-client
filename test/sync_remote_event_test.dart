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

// Subclass to mock internal protected method
class TestSyncRepository extends SyncRepository {
  String mockDeviceName = 'TestDevice';

  TestSyncRepository(
    super.apiClient, 
    super.pathService, 
    super.fileCache, 
    super.networkService, 
    super.pathResolver, 
    super.syncStateDb,
    super.hashService,
    super.conflictResolver,
    super.switchResolver,
    super.diffService,
    super.jobQueue,
    super.ref,
  );

  @override
  Future<String> getDeviceNameInternal() async => mockDeviceName;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});
  
  late TestSyncRepository repository;
  late MockApiClient mockApiClient;
  late MockSystemPathService mockPathService;
  late MockFileCache mockFileCache;
  late MockSyncNetworkService mockNetworkService;
  late MockSyncPathResolver mockPathResolver;
  late MockSyncStateDatabase mockSyncStateDb;
  late MockFileHashService mockFileHashService;
  late MockConflictResolver mockConflictResolver;
  late MockSwitchProfileResolver mockSwitchResolver;
  late MockSyncDiffService mockSyncDiffService;
  late MockSyncJobQueue mockSyncJobQueue;

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
    mockSyncDiffService = MockSyncDiffService();
    mockSyncJobQueue = MockSyncJobQueue();
    
    repository = TestSyncRepository(
      mockApiClient, 
      mockPathService, 
      mockFileCache, 
      mockNetworkService, 
      mockPathResolver, 
      mockSyncStateDb,
      mockFileHashService,
      mockConflictResolver,
      mockSwitchResolver,
      mockSyncDiffService,
      mockSyncJobQueue,
      null,
    );
    
    registerFallbackValue(<String, dynamic>{});
  });

  group('SyncRepository Remote Events', () {
    test('handleRemoteEvent should queue download for configured system', () async {
      final payload = {
        'path': 'ps2/memcards/game.ps2',
        'system_id': 'ps2',
        'origin_device': 'OtherHandheld',
        'hash': 'remotehash123',
        'size': 8388608,
        'updated_at': 1679572800000,
      };

      when(() => mockPathService.getAllSystemPaths()).thenAnswer((_) async => {'ps2': '/storage/ps2'});
      when(() => mockPathService.getEffectivePath('ps2')).thenAnswer((_) async => '/storage/ps2');
      when(() => mockPathResolver.getLocalRelPath(any(), any(), any(), any())).thenReturn('memcards/game.ps2');
      when(() => mockSyncStateDb.upsertState(any(), any(), any(), any(), any(), 
            systemId: any(named: 'systemId'), 
            remotePath: any(named: 'remotePath'), 
            relPath: any(named: 'relPath'),
            blockHashes: any(named: 'blockHashes'))).thenAnswer((_) async => Future.value());

      await repository.handleRemoteEvent(payload);

      verify(() => mockSyncStateDb.upsertState(
        any(), 
        8388608, 
        1679572800000, 
        'remotehash123', 
        'pending_download', 
        systemId: 'ps2', 
        remotePath: 'ps2/memcards/game.ps2', 
        relPath: 'memcards/game.ps2'
      )).called(1);
    });

    test('handleRemoteEvent should ignore events from self', () async {
      repository.mockDeviceName = 'MyDevice';
      
      final payload = {
        'path': 'ps2/memcards/game.ps2',
        'system_id': 'ps2',
        'origin_device': 'MyDevice', 
        'hash': 'remotehash123',
        'size': 8388608,
        'updated_at': 1679572800000,
      };

      await repository.handleRemoteEvent(payload);

      verifyNever(() => mockSyncStateDb.upsertState(any(), any(), any(), any(), any(), 
            systemId: any(named: 'systemId'), 
            remotePath: any(named: 'remotePath'), 
            relPath: any(named: 'relPath'),
            blockHashes: any(named: 'blockHashes')));
    });

    test('handleRemoteEvent should ignore events for unconfigured systems', () async {
      final payload = {
        'path': 'switch/saves/0100.sav',
        'system_id': 'switch',
        'origin_device': 'OtherDevice',
        'hash': 'remotehash123',
        'size': 1024,
        'updated_at': 1679572800000,
      };

      when(() => mockPathService.getAllSystemPaths()).thenAnswer((_) async => {'ps2': '/storage/ps2'});

      await repository.handleRemoteEvent(payload);

      verifyNever(() => mockSyncStateDb.upsertState(any(), any(), any(), any(), any(), 
            systemId: any(named: 'systemId'), 
            remotePath: any(named: 'remotePath'), 
            relPath: any(named: 'relPath'),
            blockHashes: any(named: 'blockHashes')));
    });
  });
}
