import 'dart:convert';
import 'dart:developer' as developer;
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
  final List<Future<void>> _activeHandlers = [];

  DeckyBridgeService(this._ref);

  Future<bool> _systemdBridgeActive() async {
    try {
      final isInsideFlatpak = File('/.flatpak-info').existsSync();
      final result = isInsideFlatpak
          ? await Process.run('flatpak-spawn', ['--host', 'systemctl', '--user', 'is-active', 'vaultsync-bridge'])
          : await Process.run('systemctl', ['--user', 'is-active', 'vaultsync-bridge']);
      return result.stdout.toString().trim() == 'active';
    } catch (_) {
      return false;
    }
  }

  Future<void> start({int port = 5437}) async {
    // Don't bind if the headless systemd bridge already owns port 5437.
    if (await _systemdBridgeActive()) {
      developer.log('DECKY BRIDGE: systemd service active — skipping in-process server', name: 'VaultSync', level: 800);
      return;
    }
    try {
      _server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
      developer.log('DECKY BRIDGE: Server running on ${_server!.address.address}:${_server!.port}', name: 'VaultSync', level: 800);

      _server!.listen((HttpRequest request) {
        final handler = _dispatch(request);
        _activeHandlers.add(handler);
        handler.whenComplete(() => _activeHandlers.remove(handler));
      });
    } catch (e) {
      developer.log('DECKY BRIDGE FAILED', name: 'VaultSync', level: 1000, error: e);
    }
  }

  Future<void> _dispatch(HttpRequest request) async {
    final path = request.uri.path;
    final method = request.method;
    try {
      if (path == '/status' && method == 'GET') {
        await _handleStatus(request);
      } else if (path == '/systems' && method == 'GET') {
        await _handleSystems(request);
      } else if (path == '/conflicts' && method == 'GET') {
        await _handleConflicts(request);
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

  Future<void> _handleConflicts(HttpRequest request) async {
    try {
      final syncService = _ref.read(syncServiceProvider);
      final conflicts = await syncService.getConflicts();
      _sendJsonResponse(request, {'conflicts': conflicts});
    } catch (e) {
      _sendJsonResponse(request, {'error': e.toString()}, statusCode: HttpStatus.internalServerError);
    }
  }

  Future<void> _handleGlobalSync(HttpRequest request) async {
    if (_isSyncing) {
      _sendJsonResponse(request, {'error': 'Sync already in progress'}, statusCode: HttpStatus.badRequest);
      return;
    }

    // We allow forcing a sync from the bridge even if connectivity says offline.
    // Track the async sync task so stop() can drain it before container disposal.
    final task = _triggerSync();
    _activeHandlers.add(task);
    task.whenComplete(() => _activeHandlers.remove(task));
    _sendJsonResponse(request, {'message': 'Sync triggered'});
  }

  Future<void> _handleSystemSync(HttpRequest request, String systemId) async {
    if (_isSyncing) {
      _sendJsonResponse(request, {'error': 'Sync already in progress'}, statusCode: HttpStatus.badRequest);
      return;
    }
    final task = _triggerSync(systemId: systemId);
    _activeHandlers.add(task);
    task.whenComplete(() => _activeHandlers.remove(task));
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
        await syncService.runSync(onProgress: (msg) => _lastProgress = msg, ignoreConnectivity: true);
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
    if (_activeHandlers.isNotEmpty) {
      await Future.wait(_activeHandlers);
    }
    developer.log('DECKY BRIDGE: Server stopped', name: 'VaultSync', level: 800);
  }
}
