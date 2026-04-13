import 'dart:convert';
import 'dart:io';
import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mocktail/mocktail.dart';
import 'package:http/http.dart' as http;
import 'package:vaultsync_client/core/services/decky_bridge_service.dart';
import 'package:vaultsync_client/features/sync/services/sync_service.dart';
import 'package:vaultsync_client/features/sync/services/system_path_service.dart';
import 'package:vaultsync_client/core/services/connectivity_provider.dart';
import 'package:vaultsync_client/core/services/api_client_provider.dart';
import 'package:vaultsync_client/core/services/api_client.dart';
import 'package:vaultsync_client/features/sync/domain/notification_provider.dart';
import 'package:vaultsync_client/features/sync/domain/notification_models.dart';

class MockSyncService extends Mock implements SyncService {}
class MockSystemPathService extends Mock implements SystemPathService {}
class MockApiClient extends Mock implements ApiClient {}
class MockNotificationLog extends Mock implements NotificationLogNotifier {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MockSyncService mockSyncService;
  late MockSystemPathService mockPathService;
  late MockApiClient mockApiClient;
  late MockNotificationLog mockNotificationLog;
  late ProviderContainer container;

  setUp(() {
    HttpOverrides.global = null;
    mockSyncService = MockSyncService();
    mockPathService = MockSystemPathService();
    mockApiClient = MockApiClient();
    mockNotificationLog = MockNotificationLog();

    // Register stubs up-front
    when(() => mockApiClient.getBaseUrl()).thenAnswer((_) async => 'http://test.cloud');
    
    when(() => mockPathService.getAllSystemPaths())
        .thenAnswer((_) async => {'ps2': '/path/to/ps2'});
    when(() => mockPathService.getEffectivePath(any()))
        .thenAnswer((_) async => '/path/to/system');
        
    when(() => mockSyncService.runSync(
          onProgress: any(named: 'onProgress'),
          onError: any(named: 'onError'),
          isCancelled: any(named: 'isCancelled'),
          fastSync: any(named: 'fastSync'),
          isBackground: any(named: 'isBackground'),
          ignoreConnectivity: any(named: 'ignoreConnectivity'),
        )).thenAnswer((_) async {});

    container = ProviderContainer(
      overrides: [
        syncServiceProvider.overrideWith((ref) => mockSyncService),
        systemPathServiceProvider.overrideWith((ref) => mockPathService),
        apiClientProvider.overrideWithValue(mockApiClient),
        notificationLogProvider.overrideWith((ref) => mockNotificationLog),
        isOnlineProvider.overrideWith((ref) => true),
      ],
    );
  });

  tearDown(() async {
    container.dispose();
  });

  test('DeckyBridgeService starts and responds to /status', () async {
    final service = container.read(deckyBridgeServiceProvider);
    await service.start(port: 0);
    final port = service.port;

    try {
      final response = await http.get(Uri.parse('http://127.0.0.1:$port/status')).timeout(const Duration(seconds: 5));
      expect(response.statusCode, 200);
      final data = jsonDecode(response.body);
      expect(data['is_syncing'], false);
      expect(data['is_online'], true);
    } finally {
      await service.stop();
    }
  });

  test('DeckyBridgeService /systems returns configured systems', () async {
    final service = container.read(deckyBridgeServiceProvider);
    await service.start(port: 0);
    final port = service.port;

    try {
      final response = await http.get(Uri.parse('http://127.0.0.1:$port/systems')).timeout(const Duration(seconds: 5));
      expect(response.statusCode, 200);
      final data = jsonDecode(response.body);
      expect(data['systems'], contains('ps2'));
    } finally {
      await service.stop();
    }
  });

  test('DeckyBridgeService /sync triggers global sync with ignoreConnectivity', () async {
    final service = container.read(deckyBridgeServiceProvider);
    await service.start(port: 0);
    final port = service.port;

    final completer = Completer<void>();
    when(() => mockSyncService.runSync(
          onProgress: any(named: 'onProgress'),
          ignoreConnectivity: any(named: 'ignoreConnectivity'),
        )).thenAnswer((_) async {
          completer.complete();
        });

    try {
      final response = await http.post(Uri.parse('http://127.0.0.1:$port/sync?ignoreConnectivity=true'));
      expect(response.statusCode, 200);
      
      // Wait for the fire-and-forget sync to trigger
      await completer.future.timeout(const Duration(seconds: 5));
    } finally {
      await service.stop();
    }

    verify(() => mockSyncService.runSync(
          onProgress: any(named: 'onProgress'),
          ignoreConnectivity: true,
        )).called(1);
  });
}
