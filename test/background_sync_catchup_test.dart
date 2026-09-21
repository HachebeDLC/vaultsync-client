import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vaultsync_client/features/emulation/data/emulator_repository.dart';
import 'package:vaultsync_client/features/sync/services/background_sync_service.dart';
import 'package:vaultsync_client/features/sync/services/sync_service.dart';
import 'package:vaultsync_client/features/sync/services/system_path_service.dart';

class MockSyncService extends Mock implements SyncService {}

class MockSystemPathService extends Mock implements SystemPathService {}

class MockEmulatorRepository extends Mock implements EmulatorRepository {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.vaultsync.app/launcher');

  late BackgroundSyncService service;
  late MockSyncService mockSyncService;
  late MockSystemPathService mockPathService;
  late MockEmulatorRepository mockEmulatorRepository;
  MethodCall? lastGetExitsCall;

  setUpAll(() {
    registerFallbackValue(<String>[]);
    registerFallbackValue((String msg) {});
  });

  setUp(() {
    mockSyncService = MockSyncService();
    mockPathService = MockSystemPathService();
    mockEmulatorRepository = MockEmulatorRepository();
    lastGetExitsCall = null;

    when(() => mockPathService.getEmulatorRepository())
        .thenReturn(mockEmulatorRepository);
    when(() => mockEmulatorRepository.loadSystems())
        .thenAnswer((_) async => []);
    when(() => mockPathService.getEffectivePath(any())).thenAnswer(
        (invocation) async => '/fake/${invocation.positionalArguments[0]}');
    when(() => mockSyncService.syncSpecificSystem(any(), any(),
        ignoredFolders: any(named: 'ignoredFolders'),
        onProgress: any(named: 'onProgress'))).thenAnswer((_) async {});

    service = BackgroundSyncService(mockSyncService, mockPathService,
        isAndroidOverride: true);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  /// Installs a mock handler for the platform channel that records the
  /// 'getEmulatorExitsSince' call and answers it with [exits].
  void mockNativeExits(List<Map<String, dynamic>> exits) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getEmulatorExitsSince') {
        lastGetExitsCall = call;
        return exits;
      }
      return null;
    });
  }

  test('pref off: catchUpMissedExits does nothing and returns 0', () async {
    SharedPreferences.setMockInitialValues({'auto_sync_on_exit': false});
    mockNativeExits([]);

    final handled = await service.catchUpMissedExits();

    expect(handled, 0);
    expect(lastGetExitsCall, isNull,
        reason: 'native side should never be queried when the pref is off');
    verifyNever(() => mockSyncService.syncSpecificSystem(any(), any(),
        ignoredFolders: any(named: 'ignoredFolders'),
        onProgress: any(named: 'onProgress')));
  });

  test('no checkpoint stored: queries from now minus 15 minutes', () async {
    SharedPreferences.setMockInitialValues({'auto_sync_on_exit': true});
    mockNativeExits([]);

    final lowerBound =
        DateTime.now().subtract(const Duration(minutes: 15)).millisecondsSinceEpoch;
    await service.catchUpMissedExits();
    final upperBound =
        DateTime.now().subtract(const Duration(minutes: 15)).millisecondsSinceEpoch;

    expect(lastGetExitsCall, isNotNull);
    expect(lastGetExitsCall!.method, 'getEmulatorExitsSince');
    final sinceMs = lastGetExitsCall!.arguments['sinceMs'] as int;
    // Allow a little slack for test execution time.
    expect(sinceMs, inInclusiveRange(lowerBound - 5000, upperBound + 5000));
  });

  test('exits returned: per-package sync runs for each with the right system id',
      () async {
    SharedPreferences.setMockInitialValues(
        {'auto_sync_on_exit': true, 'last_exit_check_ms': 1000});
    mockNativeExits([
      {'package': 'org.yuzu.yuzu_emu', 'closedAt': 2000},
      {'package': 'com.github.stenzek.duckstation', 'closedAt': 3000},
    ]);

    final handled = await service.catchUpMissedExits();

    expect(handled, 2);
    verify(() => mockSyncService.syncSpecificSystem('switch', any(),
        ignoredFolders: any(named: 'ignoredFolders'),
        onProgress: any(named: 'onProgress'))).called(1);
    verify(() => mockSyncService.syncSpecificSystem('ps1', any(),
        ignoredFolders: any(named: 'ignoredFolders'),
        onProgress: any(named: 'onProgress'))).called(1);
  });

  test('checkpoint is advanced to "now" after a catch-up run', () async {
    SharedPreferences.setMockInitialValues(
        {'auto_sync_on_exit': true, 'last_exit_check_ms': 1000});
    mockNativeExits([]);

    final beforeCall = DateTime.now().millisecondsSinceEpoch;
    await service.catchUpMissedExits();
    final afterCall = DateTime.now().millisecondsSinceEpoch;

    final prefs = await SharedPreferences.getInstance();
    final checkpoint = prefs.getInt('last_exit_check_ms');

    expect(checkpoint, isNotNull);
    expect(checkpoint!, greaterThanOrEqualTo(beforeCall));
    expect(checkpoint, lessThanOrEqualTo(afterCall));
  });

  test('one failing per-package sync does not stop the others', () async {
    SharedPreferences.setMockInitialValues(
        {'auto_sync_on_exit': true, 'last_exit_check_ms': 1000});
    mockNativeExits([
      {'package': 'org.yuzu.yuzu_emu', 'closedAt': 2000},
      {'package': 'com.github.stenzek.duckstation', 'closedAt': 3000},
    ]);

    when(() => mockSyncService.syncSpecificSystem('switch', any(),
        ignoredFolders: any(named: 'ignoredFolders'),
        onProgress: any(named: 'onProgress'))).thenThrow(Exception('boom'));

    final handled = await service.catchUpMissedExits();

    // Both exits were reported by the native side, even though one sync failed.
    expect(handled, 2);
    verify(() => mockSyncService.syncSpecificSystem('ps1', any(),
        ignoredFolders: any(named: 'ignoredFolders'),
        onProgress: any(named: 'onProgress'))).called(1);
  });

  test('a failed sync keeps the checkpoint so the next run retries it',
      () async {
    final storedCheckpoint =
        DateTime.now().subtract(const Duration(hours: 1)).millisecondsSinceEpoch;
    SharedPreferences.setMockInitialValues(
        {'auto_sync_on_exit': true, 'last_exit_check_ms': storedCheckpoint});
    mockNativeExits([
      {'package': 'org.yuzu.yuzu_emu', 'closedAt': storedCheckpoint + 1000},
    ]);
    when(() => mockSyncService.syncSpecificSystem('switch', any(),
        ignoredFolders: any(named: 'ignoredFolders'),
        onProgress: any(named: 'onProgress'))).thenThrow(Exception('502'));

    await service.catchUpMissedExits();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt('last_exit_check_ms'), storedCheckpoint);
  });

  test('never looks back further than 24 hours', () async {
    SharedPreferences.setMockInitialValues(
        {'auto_sync_on_exit': true, 'last_exit_check_ms': 1000});
    mockNativeExits([]);
    final floor = DateTime.now()
        .subtract(const Duration(hours: 24))
        .millisecondsSinceEpoch;

    await service.catchUpMissedExits();

    final sinceMs = (lastGetExitsCall!.arguments as Map)['sinceMs'] as int;
    expect(sinceMs, greaterThanOrEqualTo(floor));
  });
}
