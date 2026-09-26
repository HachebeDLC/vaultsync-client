import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vaultsync_client/core/errors/error_mapper.dart';
import 'package:vaultsync_client/features/emulation/data/emulator_repository.dart';
import 'package:vaultsync_client/features/sync/data/sync_repository.dart';
import 'package:vaultsync_client/features/sync/services/notification_service.dart';
import 'package:vaultsync_client/features/sync/services/power_manager_service.dart';
import 'package:vaultsync_client/features/sync/services/sync_service.dart';
import 'package:vaultsync_client/features/sync/services/system_path_service.dart';

class MockSyncRepository extends Mock implements SyncRepository {}

class MockSystemPathService extends Mock implements SystemPathService {}

class MockEmulatorRepository extends Mock implements EmulatorRepository {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SyncService syncService;
  late MockSyncRepository mockRepository;
  late MockSystemPathService mockPathService;
  late MockEmulatorRepository mockEmulatorRepository;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    mockRepository = MockSyncRepository();
    mockPathService = MockSystemPathService();
    mockEmulatorRepository = MockEmulatorRepository();

    when(() => mockPathService.getEmulatorRepository()).thenReturn(mockEmulatorRepository);
    when(() => mockEmulatorRepository.loadSystems()).thenAnswer((_) async => []);
    when(() => mockPathService.getEffectivePath(any(), onWarning: any(named: 'onWarning')))
        .thenAnswer((invocation) async => '/fake/${invocation.positionalArguments[0]}');
    when(() => mockPathService.ensureSafPermission(any())).thenAnswer((_) async => true);
    when(() => mockRepository.processManualQueue()).thenAnswer((_) async {});

    // Real, no-op on this (non-Android) test host — see their own source.
    syncService = SyncService(
      mockRepository,
      mockPathService,
      NotificationService(),
      PowerManagerService(),
    );
  });

  group('SyncService.runSync per-system error isolation', () {
    test('one system failing does not stop the others from syncing', () async {
      when(() => mockPathService.getAllSystemPaths()).thenAnswer((_) async => {
            'dc': '/fake/dc',
            'ps1': '/fake/ps1',
          });
      when(() => mockRepository.syncSystem('dc', any(),
          ignoredFolders: any(named: 'ignoredFolders'),
          saveExtensions: any(named: 'saveExtensions'),
          onProgress: any(named: 'onProgress'),
          onError: any(named: 'onError'),
          fastSync: any(named: 'fastSync'),
          isCancelled: any(named: 'isCancelled'),
          ignoreConnectivity: any(named: 'ignoreConnectivity'),
      )).thenThrow(MissingSyncFolderException(
          'dc', '/storage/emulated/0/Android/data/com.flycast.emulator/files'));
      when(() => mockRepository.syncSystem('ps1', any(),
          ignoredFolders: any(named: 'ignoredFolders'),
          saveExtensions: any(named: 'saveExtensions'),
          onProgress: any(named: 'onProgress'),
          onError: any(named: 'onError'),
          fastSync: any(named: 'fastSync'),
          isCancelled: any(named: 'isCancelled'),
          ignoreConnectivity: any(named: 'ignoreConnectivity'),
      )).thenAnswer((_) async {});

      await syncService.runSync();

      verify(() => mockRepository.syncSystem('ps1', any(),
          ignoredFolders: any(named: 'ignoredFolders'),
          saveExtensions: any(named: 'saveExtensions'),
          onProgress: any(named: 'onProgress'),
          onError: any(named: 'onError'),
          fastSync: any(named: 'fastSync'),
          isCancelled: any(named: 'isCancelled'),
          ignoreConnectivity: any(named: 'ignoreConnectivity'),
      )).called(1);
    });

    test('the aggregate error names each failed system and its real reason instead of a generic message', () async {
      when(() => mockPathService.getAllSystemPaths()).thenAnswer((_) async => {
            'dc': '/fake/dc',
            'wii': '/fake/wii',
          });
      when(() => mockRepository.syncSystem('dc', any(),
          ignoredFolders: any(named: 'ignoredFolders'),
          saveExtensions: any(named: 'saveExtensions'),
          onProgress: any(named: 'onProgress'),
          onError: any(named: 'onError'),
          fastSync: any(named: 'fastSync'),
          isCancelled: any(named: 'isCancelled'),
          ignoreConnectivity: any(named: 'ignoreConnectivity'),
      )).thenThrow(MissingSyncFolderException(
          'dc', '/storage/emulated/0/Android/data/com.flycast.emulator/files'));
      when(() => mockRepository.syncSystem('wii', any(),
          ignoredFolders: any(named: 'ignoredFolders'),
          saveExtensions: any(named: 'saveExtensions'),
          onProgress: any(named: 'onProgress'),
          onError: any(named: 'onError'),
          fastSync: any(named: 'fastSync'),
          isCancelled: any(named: 'isCancelled'),
          ignoreConnectivity: any(named: 'ignoreConnectivity'),
      )).thenThrow(Exception('boom'));

      final errors = <String>[];
      await syncService.runSync(onError: (e) => errors.add(e));

      expect(errors, hasLength(1), reason: 'one aggregate onError call, not one per system');
      // Names both systems and each one's real reason (not N identical
      // generic "Sync Failed" strings).
      expect(errors.first, contains('dc'));
      expect(errors.first, contains('Folder Not Found'));
      expect(errors.first, contains('wii'));
    });
  });
}
