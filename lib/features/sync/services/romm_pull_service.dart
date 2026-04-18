import 'dart:developer' as developer;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../../../core/services/api_client.dart';

/// Raised when `/api/v1/romm/pull` returns an error status or the streamed body
/// fails integrity verification.
class RommPullException implements Exception {
  final int statusCode;
  final String message;

  RommPullException(this.statusCode, this.message);

  @override
  String toString() => 'RommPullException($statusCode): $message';
}

/// Plaintext save bytes + RomM metadata returned by `RommPullService.pullSave`.
///
/// The caller is responsible for placing the bytes into the local vault and
/// triggering the regular encrypted-upload path — the server never handles
/// ingest, preserving the zero-knowledge guarantee.
class PulledSave {
  final int saveId;
  final int romId;
  final String fileName;
  final int size;
  final String? updatedAt;
  final String? emulator;
  final String sha256;
  final Uint8List bytes;

  const PulledSave({
    required this.saveId,
    required this.romId,
    required this.fileName,
    required this.size,
    required this.sha256,
    required this.bytes,
    this.updatedAt,
    this.emulator,
  });
}

/// Client for the `POST /api/v1/romm/pull` endpoint.
///
/// Streams a plaintext save from RomM via the VaultSync server, verifies the
/// SHA-256 echoed in the `x-romm-sha256` header matches the body, and returns
/// a `PulledSave` for the caller to ingest locally.
class RommPullService {
  final ApiClient _apiClient;

  RommPullService(this._apiClient);

  Future<PulledSave> pullSave(int romId) async {
    final response = await _apiClient.postJsonRaw(
      '/api/v1/romm/pull',
      {'rom_id': romId},
    );

    switch (response.statusCode) {
      case 200:
        break;
      case 404:
        throw RommPullException(404, 'No save available for rom_id=$romId');
      case 502:
        throw RommPullException(502, 'RomM upstream error: ${response.body}');
      case 503:
        throw RommPullException(503, 'RomM unavailable: ${response.body}');
      default:
        throw RommPullException(
          response.statusCode,
          'Unexpected status ${response.statusCode}: ${response.body}',
        );
    }

    final headers = response.headers;
    final expectedSha = headers['x-romm-sha256'];
    if (expectedSha == null || expectedSha.isEmpty) {
      throw RommPullException(200, 'Response missing x-romm-sha256 header');
    }

    final bytes = response.bodyBytes;
    final computedSha = sha256.convert(bytes).toString();
    if (computedSha != expectedSha) {
      throw RommPullException(
        200,
        'SHA-256 mismatch: expected $expectedSha, got $computedSha',
      );
    }

    final fileNameRaw = headers['x-romm-file-name'] ?? '';
    final fileName = fileNameRaw.isEmpty ? '' : Uri.decodeComponent(fileNameRaw);

    final saveId = int.tryParse(headers['x-romm-save-id'] ?? '') ?? 0;
    final romIdEcho = int.tryParse(headers['x-romm-rom-id'] ?? '') ?? romId;
    final size = int.tryParse(headers['x-romm-size'] ?? '') ?? bytes.length;

    developer.log(
      'RomM pull ok: rom=$romIdEcho save=$saveId file="$fileName" size=$size',
      name: 'VaultSync',
      level: 800,
    );

    return PulledSave(
      saveId: saveId,
      romId: romIdEcho,
      fileName: fileName,
      size: size,
      updatedAt: headers['x-romm-updated-at'],
      emulator: headers['x-romm-emulator'],
      sha256: expectedSha,
      bytes: bytes,
    );
  }
}
