import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_client_sse/constants/sse_request_type_enum.dart';
import 'package:flutter_client_sse/flutter_client_sse.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/services/api_client.dart';
import '../../../core/services/api_client_provider.dart';
import '../data/sync_repository.dart';

final syncEventServiceProvider = Provider<SyncEventService>((ref) {
  final apiClient = ref.watch(apiClientProvider);
  final repository = ref.watch(syncRepositoryProvider);
  return SyncEventService(apiClient, repository);
});

class SyncEventService {
  final ApiClient _apiClient;
  final SyncRepository _repository;
  StreamSubscription? _subscription;
  bool _isConnected = false;
  int _retryCount = 0;
  Timer? _reconnectTimer;

  SyncEventService(this._apiClient, this._repository);

  bool get isConnected => _isConnected;

  Future<void> startListening() async {
    if (_isConnected) return;
    
    String? baseUrl = await _apiClient.getBaseUrl();
    final token = await _apiClient.getToken();
    if (token == null || baseUrl == null) return;

    // Robust URL Joining
    if (baseUrl.endsWith('/')) {
      baseUrl = baseUrl.substring(0, baseUrl.length - 1);
    }
    
    // Ensure we don't double up /api/v1 if the user already has it in their settings
    String finalUrl = baseUrl;
    if (!finalUrl.contains('/api/v1')) {
      finalUrl = '$finalUrl/api/v1';
    }
    
    final deviceName = await _repository.getDeviceNameInternal();
    final url = '$finalUrl/events?device_name=${Uri.encodeComponent(deviceName)}';
    
    print('📡 SSE: Connecting to $url...');

    try {
      _subscription = SSEClient.subscribeToSSE(
        method: SSERequestType.GET,
        url: url,
        header: {
          "Authorization": "Bearer $token",
          "Accept": "text/event-stream",
          "Cache-Control": "no-cache",
        },
      ).listen(
        (event) {
          if (!_isConnected) {
            print('✅ SSE: Connected');
            _isConnected = true;
            _retryCount = 0;
          }
          
          if (event.data != null && event.data!.isNotEmpty) {
            _handleEvent(event.data!);
          }
        },
        onError: (e) {
          // Check for 404 in the error message
          if (e.toString().contains('404')) {
             print('❌ SSE: Endpoint not found (404). Check if server code is updated.');
          } else if (e.toString().contains('Connection closed while receiving data')) {
             print('⚠️ SSE: Connection reset by server or proxy. Retrying...');
          } else {
             print('⚠️ SSE Error: $e');
          }
          _handleDisconnect();
        },
        onDone: () {
          print('ℹ️ SSE Stream closed');
          _handleDisconnect();
        },
      );
    } catch (e) {
      print('❌ SSE Connection failed: $e');
      _handleDisconnect();
    }
  }

  void _handleDisconnect() {
    _isConnected = false;
    _subscription?.cancel();
    _subscription = null;
    
    if (_retryCount > 15) {
      print('🛑 SSE: Max retries exceeded. Manual sync required.');
      return;
    }

    final delay = Duration(seconds: (1 << _retryCount).clamp(5, 60));
    _retryCount++;
    
    print('🔄 SSE: Reconnecting in ${delay.inSeconds}s...');
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(delay, () => startListening());
  }

  void _handleEvent(String data) {
    try {
      final Map<String, dynamic> payload = json.decode(data);
      if (payload['type'] == 'test_notification') {
        print('🧪 SSE TEST: ${payload['message']}');
        return;
      }
      print('📥 SSE EVENT: ${payload['path']}');
      _repository.handleRemoteEvent(payload);
    } catch (e) {
      print('⚠️ SSE: Parse Error: $e');
    }
  }

  void stopListening() {
    _reconnectTimer?.cancel();
    _subscription?.cancel();
    _subscription = null;
    _isConnected = false;
    SSEClient.unsubscribeFromSSE();
    print('🛑 SSE: Listener stopped');
  }
}
