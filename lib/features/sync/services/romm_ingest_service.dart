import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../../core/services/api_client_provider.dart';
import '../data/dart_native_crypto.dart';
import '../data/sync_repository.dart';
import 'romm_pull_service.dart';
import 'sync_network_service.dart';
import 'system_path_service.dart';

final rommPullServiceProvider = Provider<RommPullService>((ref) {
  return RommPullService(ref.watch(apiClientProvider));
});

final rommIngestServiceProvider = Provider<RommIngestService>((ref) {
  return RommIngestService(
    ref.watch(rommPullServiceProvider),
    ref.watch(syncNetworkServiceProvider),
    ref.watch(systemPathServiceProvider),
    getDeviceName: () => ref.read(syncRepositoryProvider).getDeviceNameInternal(),
  );
});

/// Handles the `romm_save_newer` SSE event.
///
/// The server can see that RomM holds a save newer than the encrypted vault's
/// copy, but it cannot write RomM's plaintext into the vault itself — doing so
/// used to defeat zero-knowledge, since the server would be the one deciding
/// what ciphertext a client eventually downloads. Instead it asks a connected
/// client to do the round trip: pull the plaintext from RomM (already
/// authenticated, already over TLS), then push it back through the exact same
/// encrypted-upload path a normal save does. [SyncEventService] takes it from
/// there with its usual per-system sync, which downloads the new server copy
/// into the local folder with the usual path resolution and conflict handling
/// — this service never writes into an emulator save folder itself.
class RommIngestService {
  final RommPullService _pullService;
  final SyncNetworkService _networkService;
  final SystemPathService _pathService;
  final Future<String> Function() _getDeviceName;
  final Future<Directory> Function() _getTempDir;

  /// `path|romm_updated_at` pairs currently being pulled/uploaded.
  ///
  /// The server re-sends the same event every 10 minutes for as long as its
  /// copy stays older, so a slow ingest must not be started twice for the
  /// same (path, romm_updated_at) pair just because a second copy of the
  /// event arrived while the first was still in flight.
  final Set<String> _inFlight = {};

  RommIngestService(
    this._pullService,
    this._networkService,
    this._pathService, {
    required Future<String> Function() getDeviceName,
    Future<Directory> Function()? getTempDir,
  })  : _getDeviceName = getDeviceName,
        _getTempDir = getTempDir ?? getTemporaryDirectory;

  /// Pulls the RomM save described by [payload] and uploads it to the vault
  /// at `payload['path']`. Returns true on success, false if the event was
  /// skipped (unconfigured system, duplicate in-flight event) or the
  /// pull/upload failed.
  Future<bool> ingest(Map<String, dynamic> payload) async {
    final String path = payload['path'] as String;
    final String systemId = payload['system_id'] as String;
    final int rommId = (payload['romm_id'] as num).toInt();
    final int rommUpdatedAt = (payload['romm_updated_at'] as num).toInt();

    // Same check SyncRepository.handleRemoteEvent does: a system this device
    // has not configured has nowhere for the resulting local sync to land.
    final paths = await _pathService.getAllSystemPaths();
    if (!paths.containsKey(systemId)) {
      developer.log(
        'ROMM INGEST: Skipping $path — system "$systemId" is not configured on this device',
        name: 'VaultSync',
        level: 800,
      );
      return false;
    }

    final dedupeKey = '$path|$rommUpdatedAt';
    if (_inFlight.contains(dedupeKey)) {
      developer.log(
        'ROMM INGEST: $path (romm_updated_at=$rommUpdatedAt) is already being ingested — ignoring duplicate event',
        name: 'VaultSync',
        level: 800,
      );
      return false;
    }
    _inFlight.add(dedupeKey);

    File? tempFile;
    try {
      developer.log('ROMM INGEST: Pulling rom_id=$rommId for $path', name: 'VaultSync', level: 800);
      final pulled = await _pullService.pullSave(rommId);

      final tempDir = await _getTempDir();
      final ext = p.extension(pulled.fileName.isNotEmpty ? pulled.fileName : path);
      tempFile = File(p.join(tempDir.path, 'romm_ingest_${rommId}_$rommUpdatedAt$ext'));
      await tempFile.writeAsBytes(pulled.bytes, flush: true);

      // On desktop this is exactly what SyncNetworkService.uploadFile falls
      // back to; on Android it uses the native calculateHash instead, which
      // this helper deliberately replicates (the same double SHA-256), so the
      // value matches on every platform. Computed here so it can be logged.
      final hash = await DartNativeCrypto.calculateHash(tempFile.path);
      final deviceName = await _getDeviceName();

      developer.log(
        'ROMM INGEST: Uploading $path (${pulled.bytes.length} bytes, hash=$hash) as "$deviceName"',
        name: 'VaultSync',
        level: 800,
      );

      await _networkService.uploadFile(
        tempFile.path,
        path,
        systemId: systemId,
        relPath: p.basename(path),
        deviceName: deviceName,
        onRecordSuccess: (_, __, ___, ____) {},
        plainHash: hash,
        updatedAtOverride: rommUpdatedAt,
      );

      developer.log('ROMM INGEST: Ingested $path from RomM (rom_id=$rommId)', name: 'VaultSync', level: 800);
      return true;
    } catch (e, stack) {
      developer.log(
        'ROMM INGEST: Failed to ingest $path (rom_id=$rommId)',
        name: 'VaultSync',
        level: 1000,
        error: e,
        stackTrace: stack,
      );
      return false;
    } finally {
      _inFlight.remove(dedupeKey);
      if (tempFile != null) {
        try {
          if (await tempFile.exists()) await tempFile.delete();
        } catch (e) {
          developer.log(
            'ROMM INGEST: Failed to delete temp file ${tempFile.path}',
            name: 'VaultSync',
            level: 900,
            error: e,
          );
        }
      }
    }
  }
}
