import 'dart:convert';
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../features/sync/services/sync_service.dart';
import '../../features/sync/services/system_path_service.dart';
import '../services/connectivity_provider.dart';

final deckyBridgeServiceProvider = Provider<DeckyBridgeService>((ref) {
  return DeckyBridgeService(ref);
});

class DeckyBridgeService {
  final ProviderRef _ref;
  HttpServer? _server;
  bool _isSyncing = false;
  String _lastProgress = 'Idle';
  DateTime? _lastSyncTime;

  DeckyBridgeService(this._ref);

  Future<void> start({int port = 5437}) async {
    try {
      _server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
      print('🚀 DECKY BRIDGE: Server running on ${_server!.address.address}:${_server!.port}');
      
      _server!.listen((HttpRequest request) async {
        final path = request.uri.path;
        final method = request.method;

        try {
          if (path == '/status' && method == 'GET') {
            await _handleStatus(request);
          } else if (path == '/systems' && method == 'GET') {
            await _handleSystems(request);
          } else if (path == '/sync' && method == 'POST') {
            await _handleGlobalSync(request);
          } else if (path.startsWith('/sync/') && method == 'POST') {
            final systemId = path.substring(6);
            await _handleSystemSync(request, systemId);
          } else {
            request.response
              ..statusCode = HttpStatus.notFound
              ..write(jsonEncode({'error': 'Not Found'}))
              ..close();
          }
        } catch (e) {
          request.response
            ..statusCode = HttpStatus.internalServerError
            ..write(jsonEncode({'error': e.toString()}))
            ..close();
        }
      });
    } catch (e) {
      print('❌ DECKY BRIDGE FAILED: $e');
    }
  }

  int get port => _server?.port ?? 0;

  Future<void> _handleStatus(HttpRequest request) async {
    final isOnline = _ref.read(isOnlineProvider);
    final data = {
      'is_syncing': _isSyncing,
      'is_online': isOnline,
      'last_progress': _lastProgress,
      'last_sync_time': _lastSyncTime?.toIso8601String(),
      'timestamp': DateTime.now().toIso8601String(),
    };
    _sendJsonResponse(request, data);
  }

  Future<void> _handleSystems(HttpRequest request) async {
    final pathService = _ref.read(systemPathServiceProvider);
    final paths = await pathService.getAllSystemPaths();
    final systems = paths.keys.toList();
    _sendJsonResponse(request, {'systems': systems});
  }

  Future<void> _handleGlobalSync(HttpRequest request) async {
    if (_isSyncing) {
      _sendJsonResponse(request, {'error': 'Sync already in progress'}, statusCode: HttpStatus.badRequest);
      return;
    }
    
    // We allow forcing a sync from the bridge even if connectivity says offline
    _triggerSync();
    _sendJsonResponse(request, {'message': 'Sync triggered'});
  }

  Future<void> _handleSystemSync(HttpRequest request, String systemId) async {
    if (_isSyncing) {
      _sendJsonResponse(request, {'error': 'Sync already in progress'}, statusCode: HttpStatus.badRequest);
      return;
    }
    _triggerSync(systemId: systemId);
    _sendJsonResponse(request, {'message': 'Sync triggered for $systemId'});
  }

  void _sendJsonResponse(HttpRequest request, Map<String, dynamic> data, {int statusCode = HttpStatus.ok}) {
    request.response
      ..statusCode = statusCode
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(data))
      ..close();
  }

  Future<void> _triggerSync({String? systemId}) async {
    _isSyncing = true;
    _lastProgress = 'Starting sync...';
    try {
      final syncService = _ref.read(syncServiceProvider);
      if (systemId != null) {
        final pathService = _ref.read(systemPathServiceProvider);
        final path = await pathService.getEffectivePath(systemId);
        await syncService.syncSpecificSystem(systemId, path, onProgress: (msg) => _lastProgress = msg);
      } else {
        await syncService.runSync(onProgress: (msg) => _lastProgress = msg);
      }
      _lastSyncTime = DateTime.now();
      _lastProgress = 'Sync complete';
    } catch (e) {
      _lastProgress = 'Error: $e';
    } finally {
      _isSyncing = false;
    }
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
    print('🛑 DECKY BRIDGE: Server stopped');
  }
}
