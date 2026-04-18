/// Real-HTTP integration coverage for [RommPullService].
///
/// Unlike `romm_pull_service_test.dart` (which mocks [ApiClient] with mocktail),
/// this test stands up an in-process [HttpServer] on loopback and drives the
/// full RommPullService ↔ ApiClient ↔ dart:io socket stack against it.
///
/// This catches wire-level issues — URL construction, JSON body serialization,
/// header round-tripping, streamed response body assembly — that pure mocks
/// can't surface.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:vaultsync_client/core/services/api_client.dart';
import 'package:vaultsync_client/features/sync/services/romm_pull_service.dart';

class _FakeVaultsyncRequest {
  final Uri uri;
  final Map<String, dynamic> body;
  _FakeVaultsyncRequest(this.uri, this.body);
}

/// Spins up a minimal HTTP server impersonating vaultsync's
/// `POST /api/v1/romm/pull` endpoint.
class _FakeVaultsyncServer {
  final HttpServer _server;
  final List<_FakeVaultsyncRequest> received = [];
  final Uint8List payload;
  final Map<String, String> extraHeaders;
  final int statusCode;

  _FakeVaultsyncServer._(
    this._server,
    this.payload,
    this.extraHeaders,
    this.statusCode,
  );

  static Future<_FakeVaultsyncServer> start({
    required Uint8List payload,
    Map<String, String> extraHeaders = const {},
    int statusCode = 200,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fake = _FakeVaultsyncServer._(server, payload, extraHeaders, statusCode);
    fake._accept();
    return fake;
  }

  String get baseUrl => 'http://127.0.0.1:${_server.port}';

  void _accept() {
    _server.listen((HttpRequest req) async {
      final bodyStr = await utf8.decoder.bind(req).join();
      Map<String, dynamic> parsed = {};
      if (bodyStr.isNotEmpty) {
        try {
          parsed = json.decode(bodyStr) as Map<String, dynamic>;
        } catch (_) {
          parsed = {};
        }
      }
      received.add(_FakeVaultsyncRequest(req.uri, parsed));

      if (req.uri.path != '/api/v1/romm/pull' || req.method != 'POST') {
        req.response.statusCode = 404;
        await req.response.close();
        return;
      }

      req.response.statusCode = statusCode;
      if (statusCode == 200) {
        final digest = sha256.convert(payload).toString();
        req.response.headers.contentType =
            ContentType('application', 'octet-stream');
        req.response.headers.set('x-romm-sha256', digest);
        extraHeaders.forEach((k, v) => req.response.headers.set(k, v));
        req.response.add(payload);
      } else {
        req.response.write('err');
      }
      await req.response.close();
    });
  }

  Future<void> stop() => _server.close(force: true);
}

/// Flutter's [TestWidgetsFlutterBinding] installs an [HttpOverrides] that
/// hard-fails every real network request with HTTP 400. Restore real socket
/// I/O for this file so the loopback HttpServer is actually reachable.
class _AllowRealHttp extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = _AllowRealHttp();

  late _FakeVaultsyncServer fakeServer;
  late ApiClient apiClient;
  late RommPullService service;

  Future<void> configureClientFor(String baseUrl) async {
    SharedPreferences.setMockInitialValues({'api_base_url': baseUrl});
    apiClient = ApiClient();
    await apiClient.setBaseUrl(baseUrl);
    service = RommPullService(apiClient);
  }

  tearDown(() async {
    await fakeServer.stop();
  });

  test('E2E: real HTTP round-trip returns byte-identical payload + metadata',
      () async {
    final payload =
        Uint8List.fromList(utf8.encode('E2E_PAYLOAD_' * 512));
    fakeServer = await _FakeVaultsyncServer.start(
      payload: payload,
      extraHeaders: {
        'x-romm-save-id': '99',
        'x-romm-rom-id': '5432',
        'x-romm-file-name': Uri.encodeComponent('Super Mario (JP).sav'),
        'x-romm-size': payload.length.toString(),
        'x-romm-updated-at': '2026-04-17T09:00:00Z',
        'x-romm-emulator': 'snes9x',
      },
    );
    await configureClientFor(fakeServer.baseUrl);

    final result = await service.pullSave(5432);

    expect(result.bytes, equals(payload));
    expect(result.sha256, sha256.convert(payload).toString());
    expect(result.saveId, 99);
    expect(result.romId, 5432);
    expect(result.fileName, 'Super Mario (JP).sav');
    expect(result.size, payload.length);
    expect(result.updatedAt, '2026-04-17T09:00:00Z');
    expect(result.emulator, 'snes9x');

    expect(fakeServer.received, hasLength(1));
    expect(fakeServer.received.first.uri.path, '/api/v1/romm/pull');
    expect(fakeServer.received.first.body, {'rom_id': 5432});
  });

  test('E2E: server 404 surfaces as RommPullException(404)', () async {
    fakeServer = await _FakeVaultsyncServer.start(
      payload: Uint8List(0),
      statusCode: 404,
    );
    await configureClientFor(fakeServer.baseUrl);

    expect(
      () => service.pullSave(1),
      throwsA(isA<RommPullException>()
          .having((e) => e.statusCode, 'statusCode', 404)),
    );
  });

  test('E2E: server 502 surfaces as RommPullException(502)', () async {
    fakeServer = await _FakeVaultsyncServer.start(
      payload: Uint8List(0),
      statusCode: 502,
    );
    await configureClientFor(fakeServer.baseUrl);

    expect(
      () => service.pullSave(1),
      throwsA(isA<RommPullException>()
          .having((e) => e.statusCode, 'statusCode', 502)),
    );
  });

  test('E2E: server-side sha256 mismatch is detected by client', () async {
    final payload = Uint8List.fromList(utf8.encode('mismatch_payload'));
    // Lie about the sha256 so the client recomputes and rejects.
    final wrongDigest = sha256.convert(utf8.encode('something_else')).toString();
    fakeServer = await _FakeVaultsyncServer.start(
      payload: payload,
      extraHeaders: {
        'x-romm-sha256': wrongDigest,
        'x-romm-file-name': 'x.sav',
      },
    );
    await configureClientFor(fakeServer.baseUrl);

    expect(
      () => service.pullSave(1),
      throwsA(isA<RommPullException>()
          .having((e) => e.message, 'message', contains('SHA-256 mismatch'))),
    );
  });
}
