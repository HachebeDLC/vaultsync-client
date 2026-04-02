import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mocktail/mocktail.dart';
import 'package:http/http.dart' as http;
import 'package:vaultsync_client/core/services/decky_bridge_service.dart';
import 'package:vaultsync_client/features/sync/services/sync_service.dart';
import 'package:vaultsync_client/features/sync/services/system_path_service.dart';
import 'package:vaultsync_client/core/services/connectivity_provider.dart';

class MockSyncService extends Mock implements SyncService {}
class MockSystemPathService extends Mock implements SystemPathService {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MockSyncService mockSyncService;
  late MockSystemPathService mockPathService;
  late ProviderContainer container;

  setUp(() {
    mockSyncService = MockSyncService();
    mockPathService = MockSystemPathService();
    
    container = ProviderContainer(
      overrides: [
        syncServiceProvider.overrideWith((ref) => mockSyncService),
        systemPathServiceProvider.overrideWith((ref) => mockPathService),
        isOnlineProvider.overrideWith((ref) => true),
      ],
    );
  });

  tearDown(() {
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
    when(() => mockPathService.getAllSystemPaths()).thenAnswer((_) async => {'ps2': '/path/to/ps2'});

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
    when(() => mockSyncService.runSync(
      onProgress: any(named: 'onProgress'),
      ignoreConnectivity: true,
    )).thenAnswer((_) async => {});

    final service = container.read(deckyBridgeServiceProvider);
    await service.start(port: 0);
    final port = service.port;

    try {
      final response = await http.post(Uri.parse('http://127.0.0.1:$port/sync'));
      expect(response.statusCode, 200);
      
      // Wait for async task
      await Future.delayed(const Duration(milliseconds: 100));
      verify(() => mockSyncService.runSync(
        onProgress: any(named: 'onProgress'),
        ignoreConnectivity: true,
      )).called(1);
    } finally {
      await service.stop();
    }
  });
}
