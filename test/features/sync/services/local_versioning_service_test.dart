import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:vaultsync_client/features/sync/services/local_versioning_service.dart';
import 'package:vaultsync_client/features/sync/data/sync_state_database.dart';
import 'package:vaultsync_client/core/services/vaultsync_launcher.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class MockSyncStateDatabase extends Mock implements SyncStateDatabase {}
class MockVaultSyncLauncher extends Mock implements VaultSyncLauncher {}
class MockDatabase extends Mock implements Database {}
class MockBatch extends Mock implements Batch {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late LocalVersioningService service;
  late MockSyncStateDatabase mockDbService;
  late MockVaultSyncLauncher mockLauncher;
  late Database realDb;

  setUp(() async {
    mockDbService = MockSyncStateDatabase();
    mockLauncher = MockVaultSyncLauncher();
    realDb = await databaseFactory.openDatabase(inMemoryDatabasePath,
        options: OpenDatabaseOptions(
            version: 4,
            onCreate: (db, version) async {
              await db.execute('''
                CREATE TABLE local_versions(
                  id TEXT PRIMARY KEY,
                  systemId TEXT NOT NULL,
                  filePath TEXT NOT NULL,
                  timestamp INTEGER NOT NULL,
                  size INTEGER NOT NULL,
                  fileHash TEXT
                )
              ''');
              await db.execute('''
                CREATE TABLE version_blocks(
                  versionId TEXT NOT NULL,
                  blockIndex INTEGER NOT NULL,
                  blockHash TEXT NOT NULL,
                  PRIMARY KEY (versionId, blockIndex)
                )
              ''');
              await db.execute('''
                CREATE TABLE sync_state(
                  path TEXT PRIMARY KEY,
                  block_hashes TEXT
                )
              ''');
            }));

    when(() => mockDbService.database).thenAnswer((_) async => realDb);
    when(() => mockDbService.getState(any())).thenAnswer((inv) async {
      final path = inv.positionalArguments[0] as String;
      final result = await realDb.query('sync_state', where: 'path = ?', whereArgs: [path]);
      if (result.isNotEmpty) return result.first;
      return null;
    });
    service = LocalVersioningService(mockDbService, mockLauncher, '/tmp/versions');
  });

  tearDown(() async {
    await realDb.close();
  });

  group('LocalVersioningService', () {
    test('createSnapshot extracts changed blocks and stores metadata', () async {
      const systemId = 'ps2';
      const filePath = '/test/game.sav';
      
      // Simulate previous sync state (Version 1)
      final previousHashes = ['hash1', 'hash2', 'hash3'];
      await realDb.insert('sync_state', {
        'path': filePath,
        'block_hashes': jsonEncode(previousHashes)
      });

      // Current live file (Version 2) where block 1 has changed to 'hash2_mod'
      final currentHashes = ['hash1', 'hash2_mod', 'hash3'];
      when(() => mockLauncher.calculateBlockHashesAndHash(filePath, masterKey: null))
          .thenAnswer((_) async => {
                'blockHashes': currentHashes,
                'fileHash': 'full_file_hash_v2'
              });

      when(() => mockLauncher.extractModifiedBlocks(any(), any(), any()))
          .thenAnswer((_) async => true);

      // Perform snapshot
      final versionId = await service.createSnapshot(systemId, filePath, 5000);

      expect(versionId, isNotNull);
      verify(() => mockLauncher.extractModifiedBlocks(filePath, any(), '/tmp/versions')).called(1);

      // Verify metadata was stored in DB
      final versions = await realDb.query('local_versions');
      expect(versions.length, 1);
      expect(versions.first['id'], versionId);
      expect(versions.first['fileHash'], 'full_file_hash_v2');
      expect(versions.first['size'], 5000);

      final blocks = await realDb.query('version_blocks');
      expect(blocks.length, 3);
      expect(blocks.map((b) => b['blockHash']).toList(), containsAll(currentHashes));
    });

    test('retention policy deletes oldest versions exceeding limit', () async {
      const systemId = 'ps2';
      const filePath = '/test/game.sav';

      for (int i = 0; i < 5; i++) {
        await realDb.insert('local_versions', {
          'id': 'v_$i',
          'systemId': systemId,
          'filePath': filePath,
          'timestamp': 1000 + i,
          'size': 100,
          'fileHash': 'hash$i'
        });
      }

      when(() => mockLauncher.calculateBlockHashesAndHash(filePath, masterKey: null))
          .thenAnswer((_) async => {
                'blockHashes': ['hashNew'],
                'fileHash': 'hashNew'
              });
      when(() => mockLauncher.extractModifiedBlocks(any(), any(), any()))
          .thenAnswer((_) async => true);

      await service.createSnapshot(systemId, filePath, 100);

      final versions = await realDb.query('local_versions', orderBy: 'timestamp ASC');
      expect(versions.length, 5);
      expect(versions.first['id'], 'v_1');
    });

    test('safeRestore reconstructs to SafeRestore folder and renames live file', () async {
      const systemId = 'ps2';
      final tempDir = Directory.systemTemp.createTempSync('vaultsync_test');
      final effectivePath = tempDir.path;
      final filePath = '${tempDir.path}/live_save.sav';
      const versionId = 'v_safe';
      
      await realDb.insert('local_versions', {
        'id': versionId,
        'systemId': systemId,
        'filePath': filePath,
        'timestamp': 1000,
        'size': 100,
        'fileHash': 'hash1'
      });
      await realDb.insert('version_blocks', {
        'versionId': versionId,
        'blockIndex': 0,
        'blockHash': 'block1'
      });

      // Create the live file and safe restore mock file so renameSync doesn't fail
      File(filePath).writeAsStringSync('live data');
      File('$effectivePath/SafeRestore/live_save.sav')
        ..createSync(recursive: true)
        ..writeAsStringSync('restored data');

      when(() => mockLauncher.reconstructFromDeltas(['block1'], filePath, '$effectivePath/SafeRestore/live_save.sav', '/tmp/versions'))
          .thenAnswer((_) async => true);
      when(() => mockLauncher.mkdirs(any())).thenAnswer((_) async => true);
      when(() => mockLauncher.checkPathExists(any())).thenAnswer((_) async => true);
      when(() => mockLauncher.renameFile(any(), any())).thenAnswer((_) async => true);

      final result = await service.safeRestore(systemId, versionId, filePath, effectivePath);
      
      expect(result, isTrue);

      verify(() => mockLauncher.reconstructFromDeltas(['block1'], filePath, '$effectivePath/SafeRestore/live_save.sav', '/tmp/versions')).called(1);
    });
  });
}
