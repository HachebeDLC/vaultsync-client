import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'package:flutter_client_sse/constants/sse_request_type_enum.dart';
import 'package:flutter_client_sse/flutter_client_sse.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/services/api_client.dart';
import '../../../core/services/api_client_provider.dart';
import '../data/sync_repository.dart';
import 'romm_ingest_service.dart';
import 'sync_service.dart';
import 'system_path_service.dart';

final syncEventServiceProvider = Provider<SyncEventService>((ref) {
  final apiClient = ref.watch(apiClientProvider);
  final repository = ref.watch(syncRepositoryProvider);
  return SyncEventService(apiClient, repository, ref);
});

class SyncEventService {
  /// How long to wait for the burst to settle before syncing. A single save
  /// closing an emulator produces several file events back to back, and each
  /// one would otherwise start its own scan of the same folder.
  static const coalesceWindow = Duration(seconds: 4);

  final ApiClient _apiClient;
  final SyncRepository _repository;
  final Ref? _ref;
  StreamSubscription? _subscription;
  bool _isConnected = false;
  int _retryCount = 0;
  int _consecutive401s = 0;
  Timer? _reconnectTimer;

  /// Systems touched by events since the last flush, and the timer that will
  /// drain them. Kept as a set so a burst of 40 file events over 6 systems
  /// costs 6 syncs, not 40.
  final Set<String> _pendingSystems = {};
  Timer? _coalesceTimer;
  bool _flushing = false;

  SyncEventService(this._apiClient, this._repository, [this._ref]);

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

  Future<void> _handleEvent(String data) async {
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
      if (payload['type'] == 'romm_save_newer') {
        // The server re-sends this every 10 minutes while its copy stays
        // older than RomM's, so handling must be idempotent — RommIngestService
        // dedupes in-flight (path, romm_updated_at) pairs itself.
        developer.log('SSE: RomM save newer than vault copy: ${payload['path']}', name: 'VaultSync', level: 800);
        try {
          final ingestService = _ref?.read(rommIngestServiceProvider);
          if (ingestService == null) {
            developer.log('SSE: No RommIngestService available — cannot ingest ${payload['path']}',
                name: 'VaultSync', level: 900);
            return;
          }
          final ingested = await ingestService.ingest(payload);
          final systemId = payload['system_id'];
          // A normal per-system sync downloads the just-uploaded server copy
          // into the local folder with its existing path resolution and
          // conflict handling — this handler never writes local files itself.
          if (ingested && systemId is String) {
            _scheduleSync(systemId);
          }
        } catch (e, stack) {
          developer.log('SSE: romm_save_newer handling failed for ${payload['path']}',
              name: 'VaultSync', level: 1000, error: e, stackTrace: stack);
        }
        return;
      }
      developer.log('SSE EVENT: ${payload['path']}', name: 'VaultSync', level: 800);
      _repository.handleRemoteEvent(payload).then((systemId) {
        if (systemId != null) _scheduleSync(systemId);
      });
    } catch (e) {
      developer.log('SSE: Parse Error', name: 'VaultSync', level: 900, error: e);
    }
  }

  /// Queues [systemId] for a real sync once the event burst settles.
  void _scheduleSync(String systemId) {
    _pendingSystems.add(systemId);
    _coalesceTimer?.cancel();
    _coalesceTimer = Timer(coalesceWindow, _flushPendingSystems);
  }

  /// Runs a normal per-system sync for everything the events touched.
  ///
  /// Going through [SyncService.syncSpecificSystem] rather than resolving paths
  /// here is the point: it scans first, so path resolution has the real file
  /// list to work from, and it drains the transfer queue when it finishes.
  Future<void> _flushPendingSystems() async {
    if (_flushing || _pendingSystems.isEmpty) return;
    final systems = _pendingSystems.toList();
    _pendingSystems.clear();
    _flushing = true;

    try {
      final syncService = _ref?.read(syncServiceProvider);
      final pathService = _ref?.read(systemPathServiceProvider);
      if (syncService == null || pathService == null) {
        developer.log('SSE: No providers available to sync ${systems.join(", ")}',
            name: 'VaultSync', level: 900);
        return;
      }
      for (final systemId in systems) {
        try {
          final localPath = await pathService.getEffectivePath(systemId);
          developer.log('SSE: Syncing $systemId after remote change',
              name: 'VaultSync', level: 800);
          await syncService.syncSpecificSystem(systemId, localPath, isBackground: true);
        } catch (e) {
          // One bad system must not stop the others.
          developer.log('SSE: Sync failed for $systemId',
              name: 'VaultSync', level: 1000, error: e);
        }
      }
    } finally {
      _flushing = false;
      // Events that arrived while we were syncing still need a pass.
      if (_pendingSystems.isNotEmpty) {
        _coalesceTimer?.cancel();
        _coalesceTimer = Timer(coalesceWindow, _flushPendingSystems);
      }
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
    _coalesceTimer?.cancel();
    _pendingSystems.clear();
    _reconnectTimer?.cancel();
    _subscription?.cancel();
    _subscription = null;
    _isConnected = false;
    SSEClient.unsubscribeFromSSE();
    developer.log('SSE: Listener stopped', name: 'VaultSync', level: 800);
  }
}
