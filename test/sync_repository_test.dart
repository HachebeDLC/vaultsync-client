import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:vaultsync_client/features/sync/data/sync_repository.dart';
import 'package:vaultsync_client/features/sync/services/system_path_service.dart';
import 'package:vaultsync_client/features/sync/data/file_cache.dart';
import 'package:vaultsync_client/core/services/api_client.dart';

class MockApiClient extends Mock implements ApiClient {}
class MockSystemPathService extends Mock implements SystemPathService {}
class MockFileCache extends Mock implements FileCache {}

void main() {
  late SyncRepository repository;
  late MockApiClient mockApiClient;
  late MockSystemPathService mockPathService;
  late MockFileCache mockFileCache;

  setUp(() {
    mockApiClient = MockApiClient();
    mockPathService = MockSystemPathService();
    mockFileCache = MockFileCache();
    repository = SyncRepository(mockApiClient, mockPathService, mockFileCache);
  });

  group('SyncRepository Error Handling', () {
    test('syncSystem should call onError when API fails', () async {
      when(() => mockPathService.getEffectivePath(any())).thenAnswer((_) async => '/test/path');
      when(() => mockApiClient.get('/api/v1/files', queryParams: any(named: 'queryParams')))
          .thenThrow(Exception('Network error'));

      String? lastError;
      await repository.syncSystem(
        'ps2', 
        '/storage/emulated/0/PS2',
        onError: (err) => lastError = err,
      );

      expect(lastError, contains('Network error'));
    });
  });
}
