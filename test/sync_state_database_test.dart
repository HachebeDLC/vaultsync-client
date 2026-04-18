import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:vaultsync_client/features/sync/data/sync_state_database.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // Initialize sqflite for ffi
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late SyncStateDatabase syncDb;

  setUp(() async {
    syncDb = SyncStateDatabase(dbPathOverride: inMemoryDatabasePath);
  });

  tearDown(() async {
    final db = await syncDb.database;
    await db.close();
    // Clean up the database file
  });

  group('Versioning Schema', () {
    test('local_versions table should exist and allow inserts', () async {
      final db = await syncDb.database;
      
      final versionId = 'v_${DateTime.now().millisecondsSinceEpoch}';
      
      await db.insert('local_versions', {
        'id': versionId,
        'systemId': 'ps2',
        'filePath': 'saves/game.sav',
        'timestamp': DateTime.now().millisecondsSinceEpoch,
        'size': 10485760,
        'fileHash': 'hash123'
      });

      final result = await db.query('local_versions');
      expect(result.length, 1);
      expect(result.first['id'], versionId);
      expect(result.first['systemId'], 'ps2');
    });

    test('version_blocks table should exist and allow inserts', () async {
      final db = await syncDb.database;
      
      final versionId = 'v_${DateTime.now().millisecondsSinceEpoch}';
      
      await db.insert('version_blocks', {
        'versionId': versionId,
        'blockIndex': 0,
        'blockHash': 'blockhash000'
      });

      final result = await db.query('version_blocks');
      expect(result.length, 1);
      expect(result.first['versionId'], versionId);
      expect(result.first['blockHash'], 'blockhash000');
    });
  });

  group('SyncStateDatabase Incremental Hashing', () {
    test('should store and retrieve block hashes', () async {
      const path = '/test/path/game.sav';
      const size = 1024 * 1024 * 5;
      const lastModified = 123456789;
      const hash = 'full_file_hash';
      const status = 'synced';
      const blockHashes = '["hash1", "hash2", "hash3"]';

      // This will fail to compile or run if upsertState doesn't support blockHashes
      // @ts-ignore (in dart terms, just calling it)
      await syncDb.upsertState(
        path, 
        size, 
        lastModified, 
        hash, 
        status, 
        systemId: 'ps2',
        blockHashes: blockHashes, // This parameter doesn't exist yet
      );

      final state = await syncDb.getState(path);
      expect(state, isNotNull);
      expect(state!['block_hashes'], blockHashes);
    });

    test('should find entries containing a specific block hash', () async {
      const blockHashes1 = '["h1", "h2", "h3"]';
      const blockHashes2 = '["h3", "h4", "h5"]';
      
      await syncDb.upsertState('/p1', 100, 100, 'f1', 'synced', systemId: 's1', blockHashes: blockHashes1);
      await syncDb.upsertState('/p2', 200, 200, 'f2', 'synced', systemId: 's2', blockHashes: blockHashes2);

      // This will fail to compile if the method is missing
      final results = await syncDb.findEntriesByBlockHash('h3');
      
      expect(results.length, 2);
      expect(results.any((r) => r['path'] == '/p1'), isTrue);
      expect(results.any((r) => r['path'] == '/p2'), isTrue);

      final results2 = await syncDb.findEntriesByBlockHash('h1');
      expect(results2.length, 1);
      expect(results2.first['path'], '/p1');
    });
  });

  group('SyncStateDatabase Offline Jobs', () {
    test('should store and retrieve offline jobs', () async {
      await syncDb.upsertState('/p1', 100, 100, 'h1', 'pending_offline_upload', systemId: 's1');
      await syncDb.upsertState('/p2', 200, 200, 'h2', 'pending_offline_download', systemId: 's1');
      await syncDb.upsertState('/p3', 300, 300, 'h3', 'synced', systemId: 's1');

      final offlineJobs = await syncDb.getPendingOfflineJobs();
      expect(offlineJobs.length, 2);
      expect(offlineJobs.any((r) => r['path'] == '/p1'), isTrue);
      expect(offlineJobs.any((r) => r['path'] == '/p2'), isTrue);
      expect(offlineJobs.any((r) => r['path'] == '/p3'), isFalse);
    });

    test('should mark offline jobs as pending', () async {
      await syncDb.upsertState('/p1', 100, 100, 'h1', 'pending_offline_upload', systemId: 's1');
      await syncDb.upsertState('/p2', 200, 200, 'h2', 'pending_offline_download', systemId: 's1');

      await syncDb.markOfflineJobsAsPending();

      final offlineJobs = await syncDb.getPendingOfflineJobs();
      expect(offlineJobs.length, 0);

      final pendingJobs = await syncDb.getPendingJobs();
      expect(pendingJobs.length, 2);
      expect(pendingJobs.any((r) => r['status'] == 'pending_upload' && r['path'] == '/p1'), isTrue);
      expect(pendingJobs.any((r) => r['status'] == 'pending_download' && r['path'] == '/p2'), isTrue);
    });
  });
}
