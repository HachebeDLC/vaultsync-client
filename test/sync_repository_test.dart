import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vaultsync_client/core/errors/error_mapper.dart';
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

  setUpAll(() {
    registerFallbackValue((SharedPreferences p, String s1, String s2, String s3, {int? localTs}) => false);
    registerFallbackValue((SharedPreferences p, String s1, String s2, String s3, [int? ts]) {});
    registerFallbackValue((String s1, String s2, List<String>? l) async => []);
  });

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
      when(() => mockPathService.pathExists(any())).thenAnswer((_) async => true);
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

  group('SyncRepository missing sync folder (item 2)', () {
    test('throws MissingSyncFolderException for an uninitialized emulator Android/data folder', () async {
      const path = '/storage/emulated/0/Android/data/com.flycast.emulator/files';
      when(() => mockPathService.pathExists(path)).thenAnswer((_) async => false);
      when(() => mockPathService.mkdirs(path)).thenAnswer((_) async => false);

      expect(
        () => repository.syncSystem('dc', path),
        throwsA(isA<MissingSyncFolderException>()
            .having((e) => e.systemId, 'systemId', 'dc')
            .having((e) => e.path, 'path', path)),
      );
      // ErrorMapper turns it into a specific, actionable message rather than
      // the generic "Sync Failed" fallback.
      final userError = ErrorMapper.map(MissingSyncFolderException('dc', path));
      expect(userError.title, 'Folder Not Found');
      expect(userError.message, contains('dc'));
      expect(userError.message, contains(path));
      expect(userError.action, SyncAction.reselectFolder);
    });

    test('does not throw when the folder already exists', () async {
      const path = '/storage/emulated/0/Android/data/com.flycast.emulator/files';
      when(() => mockPathService.pathExists(path)).thenAnswer((_) async => true);
      when(() => mockConflictResolver.processLocalFiles(any(), any())).thenReturn({});
      when(() => mockDiffService.fetchAllRemoteFiles(any())).thenAnswer((_) async => []);

      // Should reach the (mocked) job-queue processing step, not throw.
      when(() => mockSyncStateDb.pruneStaleQueueRows(any(), any())).thenAnswer((_) async => 0);
      when(() => mockJobQueue.process(any(), any(), any(),
          getDeviceName: any(named: 'getDeviceName'),
          recordSyncSuccess: any(named: 'recordSyncSuccess'),
          getMasterKey: any(named: 'getMasterKey'),
          isCancelled: any(named: 'isCancelled'))).thenAnswer((_) async {});

      await repository.syncSystem('dc', path);
      verifyNever(() => mockPathService.mkdirs(any()));
    });

    test('does not throw for a folder outside Android/data even when it cannot be created', () async {
      // Out of scope for this specific check (see safNeededFor) — some other
      // path resolves the general "can't scan it" case, but not this
      // dedicated exception.
      const path = '/storage/emulated/0/SomeCustomFolder';
      when(() => mockPathService.pathExists(path)).thenAnswer((_) async => false);
      when(() => mockPathService.mkdirs(path)).thenAnswer((_) async => false);
      when(() => mockConflictResolver.processLocalFiles(any(), any())).thenReturn({});
      when(() => mockDiffService.fetchAllRemoteFiles(any())).thenAnswer((_) async => []);
      when(() => mockSyncStateDb.pruneStaleQueueRows(any(), any())).thenAnswer((_) async => 0);
      when(() => mockJobQueue.process(any(), any(), any(),
          getDeviceName: any(named: 'getDeviceName'),
          recordSyncSuccess: any(named: 'recordSyncSuccess'),
          getMasterKey: any(named: 'getMasterKey'),
          isCancelled: any(named: 'isCancelled'))).thenAnswer((_) async {});

      await repository.syncSystem('customsys', path);
    });
  });

  group('SyncRepository.getDeviceNameInternal precedence (item 3)', () {
    const channel = MethodChannel('com.vaultsync.app/launcher');

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    SyncRepository buildRepo() => SyncRepository(
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
          null,
          isAndroidOverride: true,
        );

    test('an explicit device-name pref wins over everything else', () async {
      SharedPreferences.setMockInitialValues({
        SyncRepository.kDeviceNameOverridePrefKey: 'My Custom Name',
      });
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'getDeviceSettingsName') return 'Settings Name';
        return null;
      });

      final repo = buildRepo();
      expect(await repo.getDeviceNameInternal(), 'My Custom Name');
    });

    test('falls back to Settings.Global.DEVICE_NAME via the native call when no pref is set', () async {
      SharedPreferences.setMockInitialValues({});
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'getDeviceSettingsName') return 'POCO F8 Pro';
        return null;
      });

      final repo = buildRepo();
      expect(await repo.getDeviceNameInternal(), 'POCO F8 Pro');
    });

    test('a blank pref value is treated as unset', () async {
      SharedPreferences.setMockInitialValues({
        SyncRepository.kDeviceNameOverridePrefKey: '   ',
      });
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'getDeviceSettingsName') return 'Settings Name';
        return null;
      });

      final repo = buildRepo();
      expect(await repo.getDeviceNameInternal(), 'Settings Name');
    });
  });
}
