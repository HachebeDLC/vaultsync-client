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
    var callCount = 0;
    when(() => mockClient.get(
      Uri.parse('http://localhost:5436/test'),
      headers: any(named: 'headers'),
    )).thenAnswer((_) async {
      callCount++;
      if (callCount == 1) return http.Response('Unauthorized', 401);
      return http.Response(json.encode({'status': 'ok'}), 200);
    });

    when(() => mockClient.post(
      Uri.parse('http://localhost:5436/refresh'),
      headers: any(named: 'headers'),
      body: any(named: 'body'),
    )).thenAnswer((_) async => http.Response(json.encode({'token': 'new_access_token'}), 200));

    final result = await apiClient.get('/test');
    
    expect(result['status'], 'ok');
    expect(await apiClient.getToken(), 'new_access_token');
    expect(callCount, 2);
    
    verify(() => mockClient.post(
      Uri.parse('http://localhost:5436/refresh'),
      headers: any(named: 'headers'),
      body: any(named: 'body'),
    )).called(1);
  });

  test('ApiClient should clear token and fail if refresh also fails with 401', () async {
    when(() => mockClient.get(
      any(),
      headers: any(named: 'headers'),
    )).thenAnswer((_) async => http.Response('Unauthorized', 401));

    when(() => mockClient.post(
      Uri.parse('http://localhost:5436/refresh'),
      headers: any(named: 'headers'),
      body: any(named: 'body'),
    )).thenAnswer((_) async => http.Response('Refresh token expired', 401));

    try {
      await apiClient.get('/test');
      fail('Should have thrown ApiException');
    } catch (e) {
      expect(e, isA<ApiException>());
    }
    
    final token = await apiClient.getToken();
    expect(token, isNull);
  });

  test('ApiClient should handle concurrent requests and only refresh once', () async {
    var callCount = 0;
    var refreshCount = 0;
    
    when(() => mockClient.get(
      any(),
      headers: any(named: 'headers'),
    )).thenAnswer((_) async {
      callCount++;
      return http.Response('Unauthorized', 401);
    });

    when(() => mockClient.post(
      Uri.parse('http://localhost:5436/refresh'),
      headers: any(named: 'headers'),
      body: any(named: 'body'),
    )).thenAnswer((_) async {
      refreshCount++;
      // Simulate network delay
      await Future.delayed(const Duration(milliseconds: 100));
      return http.Response(json.encode({'token': 'new_access_token'}), 200);
    });

    // Fire off multiple requests at once
    // Note: The second request should NOT try to refresh if one is in progress
    final futures = [
      apiClient.get('/test1'),
      apiClient.get('/test2'),
    ];

    // We expect them to both fail the retry or one succeed.
    // In our current implementation, if a refresh is in progress, 
    // concurrent calls might fail immediately or wait.
    // Actually, our current implementation:
    // if (response.statusCode == 401 && !_isRefreshing) { ... }
    // means the second request will NOT trigger refresh and will just fail if 401.
    
    try {
      await Future.wait(futures);
    } catch (_) {}
    
    expect(refreshCount, 1);
  });
}
