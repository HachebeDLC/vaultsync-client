import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
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
  int _consecutive401s = 0;
  Timer? _reconnectTimer;

  SyncEventService(this._apiClient, this._repository);

  bool get isConnected => _isConnected;

  Future<void> startListening() async {
    if (_isConnected) return;
    
    // If a refresh is already happening, wait for it to finish so we use the NEW token
    await _apiClient.refreshAccessToken();
    
    String? baseUrl = await _apiClient.getBaseUrl();
    final token = await _apiClient.getToken();
    if (token == null || baseUrl == null) {
      developer.log('SSE: No token or base URL. Cannot start listener.', name: 'VaultSync', level: 900);
      return;
    }

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
    
    developer.log('SSE: Connecting to $url', name: 'VaultSync', level: 800);

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
            developer.log('SSE: Connected', name: 'VaultSync', level: 800);
            _isConnected = true;
            _retryCount = 0;
            _consecutive401s = 0;
          }
          
          if (event.data != null && event.data!.isNotEmpty) {
            _handleEvent(event.data!);
          }
        },
        onError: (e) {
          final msg = e.toString();
          if (msg.contains('401') || msg.contains('Invalid or expired token') || msg.contains('Could not validate credentials')) {
            _handle401();
          } else if (msg.contains('404')) {
            developer.log('SSE: Endpoint not found (404). Check if server code is updated.', name: 'VaultSync', level: 1000);
            _handleDisconnect();
          } else if (msg.contains('Connection closed while receiving data')) {
            developer.log('SSE: Connection reset by server or proxy. Retrying.', name: 'VaultSync', level: 900);
            _handleDisconnect();
          } else {
            developer.log('SSE Error', name: 'VaultSync', level: 900, error: e);
            _handleDisconnect();
          }
        },
        onDone: () {
          developer.log('SSE Stream closed', name: 'VaultSync', level: 800);
          _handleDisconnect();
        },
      );
    } catch (e) {
      developer.log('SSE Connection failed', name: 'VaultSync', level: 1000, error: e);
      _handleDisconnect();
    }
  }

  void _handleDisconnect() {
    _isConnected = false;
    _subscription?.cancel();
    _subscription = null;
    
    if (_retryCount > 15) {
      developer.log('SSE: Max retries exceeded. Manual sync required.', name: 'VaultSync', level: 900);
      return;
    }

    final delay = Duration(seconds: (1 << _retryCount).clamp(5, 60));
    _retryCount++;
    
    developer.log('SSE: Reconnecting in ${delay.inSeconds}s', name: 'VaultSync', level: 800);
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(delay, () => startListening());
  }

  void _handleEvent(String data) {
    // The SSE library may surface a 401 response body as event data.
    if (data.contains('Invalid or expired token') || data.contains('Could not validate credentials')) {
      _handle401();
      return;
    }
    try {
      final Map<String, dynamic> payload = json.decode(data);
      if (payload['type'] == 'test_notification') {
        developer.log('SSE TEST: ${payload['message']}', name: 'VaultSync', level: 800);
        return;
      }
      developer.log('SSE EVENT: ${payload['path']}', name: 'VaultSync', level: 800);
      _repository.handleRemoteEvent(payload);
    } catch (e) {
      developer.log('SSE: Parse Error', name: 'VaultSync', level: 900, error: e);
    }
  }

  Future<void> _handle401() async {
    if (!_isConnected && _subscription == null) return; // Already handling or stopped

    _isConnected = false;
    _subscription?.cancel();
    _subscription = null;
    _reconnectTimer?.cancel();
    SSEClient.unsubscribeFromSSE();

    _consecutive401s++;
    developer.log('SSE: Token expired (consecutive 401s: $_consecutive401s) — attempting refresh', name: 'VaultSync', level: 900);

    // Give up after 3 consecutive 401s — refresh isn't helping
    if (_consecutive401s >= 3) {
      developer.log('SSE: Persistent 401 after $_consecutive401s attempts. Stopping event listener. Manual sync required.', name: 'VaultSync', level: 1000);
      _consecutive401s = 0;
      return;
    }

    final refreshed = await _apiClient.refreshAccessToken();

    if (refreshed) {
      developer.log('SSE: Token refreshed, reconnecting', name: 'VaultSync', level: 800);
      _retryCount = 0;
      // Use a small delay to ensure the server-side Redis/listener is ready for a new connection
      _reconnectTimer = Timer(const Duration(seconds: 1), () => startListening());
    } else {
      // If refresh failed, check if it was a terminal failure (token cleared)
      final token = await _apiClient.getToken();
      if (token == null) {
        developer.log('SSE: Session is terminal (logged out). Stopping event listener.', name: 'VaultSync', level: 1000);
        _consecutive401s = 0;
        return;
      }

      // If we still have a token but refresh failed (e.g. network error), do a backoff retry
      developer.log('SSE: Token refresh failed (possibly network). Backing off.', name: 'VaultSync', level: 900);
      _handleDisconnect();
    }
  }

  void stopListening() {
    _reconnectTimer?.cancel();
    _subscription?.cancel();
    _subscription = null;
    _isConnected = false;
    SSEClient.unsubscribeFromSSE();
    developer.log('SSE: Listener stopped', name: 'VaultSync', level: 800);
  }
}
