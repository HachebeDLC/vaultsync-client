// Covers the 401-classify -> refresh -> retry-once logic inside
// SyncNetworkService._executeNative (the wrapper every native download/upload
// call goes through).
//
// Background (real device, POCO F8 Pro, Android 16): a native download hit
// `/api/v1/download` with a token captured just before a concurrent refresh
// completed, got a 401, and that 401 was not turned into "refresh and retry
// with the new token" reliably enough to prevent a corrupted rollback. This
// retry path already existed in _executeNative; these tests pin its exact
// behavior — one refresh, one retry, using the NEW token, and never more than
// one retry even if the retry also 401s — using the `debugNativeOverride`
// test seam (see SyncNetworkService) instead of a real platform channel or
// network call.
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:vaultsync_client/core/services/api_client.dart';
import 'package:vaultsync_client/features/sync/services/sync_network_service.dart';

class MockApiClient extends Mock implements ApiClient {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MockApiClient mockApiClient;
  late SyncNetworkService service;

  setUp(() {
    mockApiClient = MockApiClient();
    service = SyncNetworkService(mockApiClient);

    when(() => mockApiClient.getBaseUrl()).thenAnswer((_) async => 'https://vaultsync.example');
    when(() => mockApiClient.getEncryptionKey()).thenAnswer((_) async => 'master-key');
  });

  Future<dynamic> download() => service.downloadFile(
        'switch/save.bin',
        '/local/switch',
        'save.bin',
        systemId: 'switch',
        fileSize: 10,
        onRecordSuccess: (systemId, relPath, hash, ts) {},
      );

  test('(iii) 401 then success: refreshes once and retries once using the NEW token', () async {
    String currentToken = 'stale-token';
    var refreshCalls = 0;
    when(() => mockApiClient.getToken()).thenAnswer((_) async => currentToken);
    when(() => mockApiClient.refreshAccessToken()).thenAnswer((_) async {
      refreshCalls++;
      currentToken = 'fresh-token';
      return true;
    });

    var nativeCalls = 0;
    final seenTokens = <String?>[];
    service.debugNativeOverride = (methodName, args) async {
      nativeCalls++;
      seenTokens.add(args['token'] as String?);
      if (nativeCalls == 1) {
        throw Exception('Download failed: HTTP 401 Unauthorized');
      }
      return {'size': 10, 'lastModified': 1000};
    };

    final result = await download();

    expect(nativeCalls, 2, reason: 'exactly one retry after the 401, no loop');
    expect(refreshCalls, 1);
    expect(seenTokens, ['stale-token', 'fresh-token'],
        reason: 'the retry must use the token produced by refreshAccessToken, not the stale one');
    expect(result, {'size': 10, 'lastModified': 1000});
  });

  test('(iv) 401 twice: surfaces an error after exactly one retry attempt, no loop', () async {
    when(() => mockApiClient.getToken()).thenAnswer((_) async => 'token');
    when(() => mockApiClient.refreshAccessToken()).thenAnswer((_) async => true);

    var nativeCalls = 0;
    service.debugNativeOverride = (methodName, args) async {
      nativeCalls++;
      throw Exception('Download failed: HTTP 401 Unauthorized');
    };

    await expectLater(
      download,
      throwsA(isA<ApiException>().having((e) => e.statusCode, 'statusCode', 401)),
    );

    expect(nativeCalls, 2, reason: 'the original attempt plus exactly one retry — never more');
    verify(() => mockApiClient.refreshAccessToken()).called(1);
  });

  test('401 when the refresh itself fails: surfaces immediately without ever retrying the native call', () async {
    when(() => mockApiClient.getToken()).thenAnswer((_) async => 'token');
    when(() => mockApiClient.refreshAccessToken()).thenAnswer((_) async => false);

    var nativeCalls = 0;
    service.debugNativeOverride = (methodName, args) async {
      nativeCalls++;
      throw Exception('Download failed: HTTP 401 Unauthorized');
    };

    await expectLater(
      download,
      throwsA(isA<ApiException>().having((e) => e.statusCode, 'statusCode', 401)),
    );

    expect(nativeCalls, 1, reason: 'no point retrying the native call when the token could not be refreshed at all');
  });

  test('a non-401 native failure is never treated as an auth failure (no refresh, no retry)', () async {
    var nativeCalls = 0;
    when(() => mockApiClient.getToken()).thenAnswer((_) async => 'token');
    service.debugNativeOverride = (methodName, args) async {
      nativeCalls++;
      throw Exception('Download failed: HTTP 404 Not Found');
    };

    await expectLater(download, throwsException);

    expect(nativeCalls, 1);
    verifyNever(() => mockApiClient.refreshAccessToken());
  });
}
