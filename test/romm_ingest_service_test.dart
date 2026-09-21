import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:vaultsync_client/features/sync/data/dart_native_crypto.dart';
import 'package:vaultsync_client/features/sync/services/romm_ingest_service.dart';
import 'package:vaultsync_client/features/sync/services/romm_pull_service.dart';
import 'package:vaultsync_client/features/sync/services/sync_network_service.dart';
import 'package:vaultsync_client/features/sync/services/system_path_service.dart';

class MockRommPullService extends Mock implements RommPullService {}
class MockSyncNetworkService extends Mock implements SyncNetworkService {}
class MockSystemPathService extends Mock implements SystemPathService {}

/// Writes [bytes] to a throwaway file under [dir] and hashes it with the
/// exact helper the normal upload path uses, so tests can assert on the hash
/// RommIngestService is expected to compute without re-implementing it.
Future<String> _expectedHash(Directory dir, List<int> bytes) async {
  final f = File('${dir.path}/expected_hash_source');
  await f.writeAsBytes(bytes, flush: true);
  final hash = await DartNativeCrypto.calculateHash(f.path);
  await f.delete();
  return hash;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MockRommPullService mockPullService;
  late MockSyncNetworkService mockNetworkService;
  late MockSystemPathService mockPathService;
  late Directory tempDir;
  late RommIngestService service;

  final samplePayload = {
    'type': 'romm_save_newer',
    'path': 'ps2/saves/game.ps2',
    'system_id': 'ps2',
    'romm_id': 42,
    'romm_updated_at': 1700000000000,
  };

  setUp(() async {
    mockPullService = MockRommPullService();
    mockNetworkService = MockSyncNetworkService();
    mockPathService = MockSystemPathService();
    tempDir = await Directory.systemTemp.createTemp('romm_ingest_test_');

    service = RommIngestService(
      mockPullService,
      mockNetworkService,
      mockPathService,
      getDeviceName: () async => 'TestDevice',
      getTempDir: () async => tempDir,
    );

    registerFallbackValue(<String, dynamic>{});
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  PulledSave pulledSaveFor(Uint8List bytes) => PulledSave(
        saveId: 7,
        romId: 42,
        fileName: 'game.ps2',
        size: bytes.length,
        sha256: 'irrelevant-for-these-tests',
        bytes: bytes,
      );

  group('RommIngestService.ingest', () {
    test('skips ingest when the system is not configured on this device', () async {
      when(() => mockPathService.getAllSystemPaths())
          .thenAnswer((_) async => {'gc': '/storage/gc'}); // no 'ps2'

      final result = await service.ingest(samplePayload);

      expect(result, isFalse);
      verifyNever(() => mockPullService.pullSave(any()));
      verifyNever(() => mockNetworkService.uploadFile(
            any(),
            any(),
            systemId: any(named: 'systemId'),
            relPath: any(named: 'relPath'),
            deviceName: any(named: 'deviceName'),
            onRecordSuccess: any(named: 'onRecordSuccess'),
            plainHash: any(named: 'plainHash'),
            localBlockHashes: any(named: 'localBlockHashes'),
            force: any(named: 'force'),
            rommKey: any(named: 'rommKey'),
            rommUrl: any(named: 'rommUrl'),
            rommApiKey: any(named: 'rommApiKey'),
            updatedAtOverride: any(named: 'updatedAtOverride'),
          ));
    });

    test('pulls the save and uploads it to payload["path"] with romm_updated_at', () async {
      when(() => mockPathService.getAllSystemPaths())
          .thenAnswer((_) async => {'ps2': '/storage/ps2'});

      final bytes = Uint8List.fromList(utf8.encode('PS2_SAVE_BYTES' * 8));
      when(() => mockPullService.pullSave(42))
          .thenAnswer((_) async => pulledSaveFor(bytes));

      final expectedHash = await _expectedHash(tempDir, bytes);

      when(() => mockNetworkService.uploadFile(
            captureAny(),
            captureAny(),
            systemId: captureAny(named: 'systemId'),
            relPath: captureAny(named: 'relPath'),
            deviceName: captureAny(named: 'deviceName'),
            onRecordSuccess: any(named: 'onRecordSuccess'),
            plainHash: captureAny(named: 'plainHash'),
            localBlockHashes: any(named: 'localBlockHashes'),
            force: any(named: 'force'),
            rommKey: any(named: 'rommKey'),
            rommUrl: any(named: 'rommUrl'),
            rommApiKey: any(named: 'rommApiKey'),
            updatedAtOverride: captureAny(named: 'updatedAtOverride'),
          )).thenAnswer((_) async {});

      final result = await service.ingest(samplePayload);

      expect(result, isTrue);

      final captured = verify(() => mockNetworkService.uploadFile(
            captureAny(),
            captureAny(),
            systemId: captureAny(named: 'systemId'),
            relPath: captureAny(named: 'relPath'),
            deviceName: captureAny(named: 'deviceName'),
            onRecordSuccess: any(named: 'onRecordSuccess'),
            plainHash: captureAny(named: 'plainHash'),
            localBlockHashes: any(named: 'localBlockHashes'),
            force: any(named: 'force'),
            rommKey: any(named: 'rommKey'),
            rommUrl: any(named: 'rommUrl'),
            rommApiKey: any(named: 'rommApiKey'),
            updatedAtOverride: captureAny(named: 'updatedAtOverride'),
          )).captured;

      // Capture order follows the order captureAny()/captureAny(named:) were
      // written above: [localPath, remotePath, systemId, relPath, deviceName,
      // plainHash, updatedAtOverride].
      final localPath = captured[0] as String;
      final remotePath = captured[1] as String;
      final capturedSystemId = captured[2] as String;
      final capturedRelPath = captured[3] as String;
      final capturedDeviceName = captured[4] as String;
      final capturedHash = captured[5] as String;
      final capturedUpdatedAt = captured[6] as int;

      expect(remotePath, samplePayload['path'] as String);
      expect(capturedSystemId, 'ps2');
      expect(capturedRelPath, 'game.ps2');
      expect(capturedDeviceName, 'TestDevice');
      expect(capturedUpdatedAt, samplePayload['romm_updated_at'] as int);
      expect(capturedHash, expectedHash);
      // The temp file existed (and lived under our temp dir) at upload time —
      // it's deleted by the time ingest() returns (checked below).
      expect(localPath, startsWith(tempDir.path));
      expect(await File(localPath).exists(), isFalse);
    });

    test('deletes the temp file even when the upload throws', () async {
      when(() => mockPathService.getAllSystemPaths())
          .thenAnswer((_) async => {'ps2': '/storage/ps2'});

      final bytes = Uint8List.fromList(utf8.encode('SAVE_THAT_FAILS_TO_UPLOAD'));
      when(() => mockPullService.pullSave(42))
          .thenAnswer((_) async => pulledSaveFor(bytes));

      String? capturedPath;
      when(() => mockNetworkService.uploadFile(
            any(),
            any(),
            systemId: any(named: 'systemId'),
            relPath: any(named: 'relPath'),
            deviceName: any(named: 'deviceName'),
            onRecordSuccess: any(named: 'onRecordSuccess'),
            plainHash: any(named: 'plainHash'),
            localBlockHashes: any(named: 'localBlockHashes'),
            force: any(named: 'force'),
            rommKey: any(named: 'rommKey'),
            rommUrl: any(named: 'rommUrl'),
            rommApiKey: any(named: 'rommApiKey'),
            updatedAtOverride: any(named: 'updatedAtOverride'),
          )).thenAnswer((invocation) async {
        // Capture + confirm the file is actually there while upload "runs",
        // before ingest's finally block gets a chance to delete it.
        capturedPath = invocation.positionalArguments[0] as String;
        expect(await File(capturedPath!).exists(), isTrue);
        throw Exception('simulated upload failure');
      });

      final result = await service.ingest(samplePayload);

      expect(result, isFalse);
      expect(capturedPath, isNotNull);
      expect(await File(capturedPath!).exists(), isFalse);
    });

    test('ignores a duplicate in-flight payload for the same (path, romm_updated_at)', () async {
      when(() => mockPathService.getAllSystemPaths())
          .thenAnswer((_) async => {'ps2': '/storage/ps2'});

      final bytes = Uint8List.fromList(utf8.encode('SLOW_PULL_BYTES'));
      final pullCompleter = Completer<PulledSave>();
      when(() => mockPullService.pullSave(42)).thenAnswer((_) => pullCompleter.future);

      when(() => mockNetworkService.uploadFile(
            any(),
            any(),
            systemId: any(named: 'systemId'),
            relPath: any(named: 'relPath'),
            deviceName: any(named: 'deviceName'),
            onRecordSuccess: any(named: 'onRecordSuccess'),
            plainHash: any(named: 'plainHash'),
            localBlockHashes: any(named: 'localBlockHashes'),
            force: any(named: 'force'),
            rommKey: any(named: 'rommKey'),
            rommUrl: any(named: 'rommUrl'),
            rommApiKey: any(named: 'rommApiKey'),
            updatedAtOverride: any(named: 'updatedAtOverride'),
          )).thenAnswer((_) async {});

      // Start the first ingest but don't let the pull resolve yet.
      final firstFuture = service.ingest(samplePayload);

      // A second, identical event arrives while the first is still in flight.
      final secondResult = await service.ingest(samplePayload);
      expect(secondResult, isFalse);

      // Let the first pull complete and finish the first ingest.
      pullCompleter.complete(pulledSaveFor(bytes));
      final firstResult = await firstFuture;
      expect(firstResult, isTrue);

      verify(() => mockPullService.pullSave(42)).called(1);
    });
  });
}
