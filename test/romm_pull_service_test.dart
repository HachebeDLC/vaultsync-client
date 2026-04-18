import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:mocktail/mocktail.dart';

import 'package:vaultsync_client/core/services/api_client.dart';
import 'package:vaultsync_client/features/sync/services/romm_pull_service.dart';

class MockApiClient extends Mock implements ApiClient {}

http.Response _okResponse(Uint8List body, Map<String, String> headers) {
  return http.Response.bytes(body, 200, headers: headers);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MockApiClient mockApi;
  late RommPullService service;

  setUp(() {
    mockApi = MockApiClient();
    service = RommPullService(mockApi);
    registerFallbackValue(<String, dynamic>{});
  });

  group('RommPullService.pullSave', () {
    test('happy path returns PulledSave with decoded metadata + verified bytes',
        () async {
      final bytes = Uint8List.fromList(utf8.encode('PLAINTEXT_SAVE_BYTES' * 16));
      final digest = sha256.convert(bytes).toString();
      final encodedName = Uri.encodeComponent('My Save (USA).sav');

      when(() => mockApi.postJsonRaw('/api/v1/romm/pull', {'rom_id': 123}))
          .thenAnswer((_) async => _okResponse(bytes, {
                'x-romm-sha256': digest,
                'x-romm-save-id': '42',
                'x-romm-rom-id': '123',
                'x-romm-file-name': encodedName,
                'x-romm-size': bytes.length.toString(),
                'x-romm-updated-at': '2026-04-17T00:00:00Z',
                'x-romm-emulator': 'snes9x',
              }));

      final result = await service.pullSave(123);

      expect(result.bytes, equals(bytes));
      expect(result.sha256, equals(digest));
      expect(result.saveId, 42);
      expect(result.romId, 123);
      expect(result.fileName, 'My Save (USA).sav');
      expect(result.size, bytes.length);
      expect(result.updatedAt, '2026-04-17T00:00:00Z');
      expect(result.emulator, 'snes9x');
    });

    test('missing save id / size headers fall back to 0 and body length',
        () async {
      final bytes = Uint8List.fromList([1, 2, 3, 4, 5]);
      final digest = sha256.convert(bytes).toString();

      when(() => mockApi.postJsonRaw(any(), any()))
          .thenAnswer((_) async => _okResponse(bytes, {
                'x-romm-sha256': digest,
                'x-romm-file-name': '',
              }));

      final result = await service.pullSave(9);

      expect(result.saveId, 0);
      expect(result.romId, 9);
      expect(result.size, bytes.length);
      expect(result.fileName, '');
      expect(result.updatedAt, isNull);
      expect(result.emulator, isNull);
    });

    test('404 maps to RommPullException(404)', () async {
      when(() => mockApi.postJsonRaw(any(), any()))
          .thenAnswer((_) async => http.Response('no save', 404));

      expect(
        () => service.pullSave(1),
        throwsA(isA<RommPullException>()
            .having((e) => e.statusCode, 'statusCode', 404)),
      );
    });

    test('502 maps to RommPullException(502)', () async {
      when(() => mockApi.postJsonRaw(any(), any()))
          .thenAnswer((_) async => http.Response('bad gateway', 502));

      expect(
        () => service.pullSave(1),
        throwsA(isA<RommPullException>()
            .having((e) => e.statusCode, 'statusCode', 502)),
      );
    });

    test('503 maps to RommPullException(503)', () async {
      when(() => mockApi.postJsonRaw(any(), any()))
          .thenAnswer((_) async => http.Response('romm down', 503));

      expect(
        () => service.pullSave(1),
        throwsA(isA<RommPullException>()
            .having((e) => e.statusCode, 'statusCode', 503)),
      );
    });

    test('unexpected status (e.g. 500) throws RommPullException with that code',
        () async {
      when(() => mockApi.postJsonRaw(any(), any()))
          .thenAnswer((_) async => http.Response('boom', 500));

      expect(
        () => service.pullSave(1),
        throwsA(isA<RommPullException>()
            .having((e) => e.statusCode, 'statusCode', 500)),
      );
    });

    test('missing x-romm-sha256 header throws', () async {
      final bytes = Uint8List.fromList([9, 9, 9]);

      when(() => mockApi.postJsonRaw(any(), any()))
          .thenAnswer((_) async => _okResponse(bytes, {
                'x-romm-file-name': 'x.sav',
              }));

      expect(
        () => service.pullSave(1),
        throwsA(isA<RommPullException>()
            .having((e) => e.message, 'message', contains('x-romm-sha256'))),
      );
    });

    test('sha256 mismatch throws', () async {
      final bytes = Uint8List.fromList(utf8.encode('REAL_BYTES'));
      // Deliberately wrong digest.
      final wrongDigest = sha256.convert(utf8.encode('OTHER')).toString();

      when(() => mockApi.postJsonRaw(any(), any()))
          .thenAnswer((_) async => _okResponse(bytes, {
                'x-romm-sha256': wrongDigest,
                'x-romm-file-name': 'x.sav',
              }));

      expect(
        () => service.pullSave(1),
        throwsA(isA<RommPullException>()
            .having((e) => e.message, 'message', contains('SHA-256 mismatch'))),
      );
    });

    test('URL-encoded x-romm-file-name is decoded', () async {
      final bytes = Uint8List.fromList([1, 2, 3]);
      final digest = sha256.convert(bytes).toString();
      // Spaces, parens, and an ampersand — all require URL encoding.
      final raw = 'Kirby & Friends (USA).sav';
      final encoded = Uri.encodeComponent(raw);

      when(() => mockApi.postJsonRaw(any(), any()))
          .thenAnswer((_) async => _okResponse(bytes, {
                'x-romm-sha256': digest,
                'x-romm-file-name': encoded,
              }));

      final result = await service.pullSave(1);
      expect(result.fileName, raw);
    });
  });
}
