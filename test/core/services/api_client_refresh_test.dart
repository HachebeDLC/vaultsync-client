import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vaultsync_client/core/services/api_client.dart';
import 'dart:convert';

class MockHttpClient extends Mock implements http.Client {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  
  final Map<String, String> mockStorage = {};
  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

  late ApiClient apiClient;
  late MockHttpClient mockClient;
  
  setUp(() async {
    mockStorage.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
      if (methodCall.method == 'write') {
        mockStorage[methodCall.arguments['key']] = methodCall.arguments['value'];
        return null;
      }
      if (methodCall.method == 'read') {
        return mockStorage[methodCall.arguments['key']];
      }
      if (methodCall.method == 'delete') {
        mockStorage.remove(methodCall.arguments['key']);
        return null;
      }
      return null;
    });

    registerFallbackValue(Uri.parse('http://localhost'));
    SharedPreferences.setMockInitialValues({
      'api_base_url': 'http://localhost:5436',
    });
    mockClient = MockHttpClient();
    apiClient = ApiClient(client: mockClient);
    await apiClient.setRefreshToken('old_refresh_token');
    await apiClient.setToken('old_access_token');
  });

  test('ApiClient should refresh token on 401 and retry', () async {
    // 1. First call fails with 401, second (retry) succeeds
    var callCount = 0;
    when(() => mockClient.get(
      Uri.parse('http://localhost:5436/test'),
      headers: any(named: 'headers'),
    )).thenAnswer((_) async {
      callCount++;
      if (callCount == 1) return http.Response('Unauthorized', 401);
      return http.Response(json.encode({'status': 'ok'}), 200);
    });

    // 2. Refresh call succeeds
    when(() => mockClient.post(
      Uri.parse('http://localhost:5436/api/v1/auth/refresh'),
      headers: any(named: 'headers'),
      body: any(named: 'body'),
    )).thenAnswer((_) async => http.Response(json.encode({'token': 'new_access_token'}), 200));

    final result = await apiClient.get('/test');

    expect(result['status'], 'ok');
    expect(await apiClient.getToken(), 'new_access_token');
    expect(callCount, 2); // Verify it was called twice

    // Verify refresh was called
    verify(() => mockClient.post(
      Uri.parse('http://localhost:5436/api/v1/auth/refresh'),
      headers: any(named: 'headers'),
      body: any(named: 'body'),
    )).called(1);
  });
}
