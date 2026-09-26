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

  // Covers SyncRepository.syncSystem's pre-diff cleanup: rows keyed by a URI
  // shape the SAF scanner can never emit (the download-destination fix in
  // sync_job_queue.dart), and rows left behind under a since-replaced SAF
  // grant. Only 'synced' rows of these two dead shapes are ever removed —
  // pending/failed rows are real queued work.
  group('cleanupDeadContentUriRows', () {
    const currentRoot =
        'content://com.android.externalstorage.documents/tree/primary%3AAndroid%2Fdata%2Fdev.eden.eden_emulator';
    const staleRoot =
        'content://com.android.externalstorage.documents/tree/primary%3AAndroid%2Fdata%2Fdev.eden.eden_emulator%2Ffiles';

    const treePathShaped = '$currentRoot/nand/user/save/0000000000000000/deadbeef/rep_gamedata1.dat';
    const currentRootDocUri = '$currentRoot/document/primary%3Asomething%2Fdoc123';
    const staleRootDocUri = '$staleRoot/document/primary%3Asomething%2Fdoc456';
    const nonContentPath = '/storage/emulated/0/RetroArch/saves/game.srm';

    test('deletes synced tree+path shaped rows (no /document/ segment)', () async {
      await syncDb.upsertState(treePathShaped, 100, 100, 'h', 'synced', systemId: 'switch');

      final removed = await syncDb.cleanupDeadContentUriRows('switch', currentRoot);

      expect(removed, 1);
      expect(await syncDb.getState(treePathShaped), isNull);
    });

    test('deletes synced rows whose tree root differs from the current root', () async {
      await syncDb.upsertState(staleRootDocUri, 100, 100, 'h', 'synced', systemId: 'switch');

      final removed = await syncDb.cleanupDeadContentUriRows('switch', currentRoot);

      expect(removed, 1);
      expect(await syncDb.getState(staleRootDocUri), isNull);
    });

    test('keeps synced document-uri rows under the current root', () async {
      await syncDb.upsertState(currentRootDocUri, 100, 100, 'h', 'synced', systemId: 'switch');

      final removed = await syncDb.cleanupDeadContentUriRows('switch', currentRoot);

      expect(removed, 0);
      expect(await syncDb.getState(currentRootDocUri), isNotNull);
    });

    test('never removes pending or failed rows, even when dead-shaped', () async {
      await syncDb.upsertState(treePathShaped, 100, 100, 'h', 'pending_download', systemId: 'switch');
      await syncDb.upsertState(staleRootDocUri, 100, 100, 'h', 'failed', systemId: 'switch');

      final removed = await syncDb.cleanupDeadContentUriRows('switch', currentRoot);

      expect(removed, 0);
      expect(await syncDb.getState(treePathShaped), isNotNull);
      expect(await syncDb.getState(staleRootDocUri), isNotNull);
    });

    test('never touches rows for a different systemId', () async {
      await syncDb.upsertState(treePathShaped, 100, 100, 'h', 'synced', systemId: 'other-system');

      final removed = await syncDb.cleanupDeadContentUriRows('switch', currentRoot);

      expect(removed, 0);
      expect(await syncDb.getState(treePathShaped), isNotNull);
    });

    test('ignores non-content:// paths entirely', () async {
      await syncDb.upsertState(nonContentPath, 100, 100, 'h', 'synced', systemId: 'retroarch');

      final removed = await syncDb.cleanupDeadContentUriRows('retroarch', '/storage/emulated/0/RetroArch/saves');

      expect(removed, 0);
      expect(await syncDb.getState(nonContentPath), isNotNull);
    });

    test('also removes the row from sync_block_hashes', () async {
      await syncDb.upsertState(
        treePathShaped, 100, 100, 'h', 'synced',
        systemId: 'switch',
        blockHashes: '["bh1", "bh2"]',
      );

      final removed = await syncDb.cleanupDeadContentUriRows('switch', currentRoot);

      expect(removed, 1);
      final db = await syncDb.database;
      final blockRows = await db.query('sync_block_hashes', where: 'path = ?', whereArgs: [treePathShaped]);
      expect(blockRows, isEmpty);
    });

    test('does not touch local_versions', () async {
      final db = await syncDb.database;
      await db.insert('local_versions', {
        'id': 'v1',
        'systemId': 'switch',
        'filePath': 'rep_gamedata1.dat',
        'timestamp': 1000,
        'size': 100,
        'fileHash': 'h',
      });
      await syncDb.upsertState(treePathShaped, 100, 100, 'h', 'synced', systemId: 'switch');

      await syncDb.cleanupDeadContentUriRows('switch', currentRoot);

      final versions = await db.query('local_versions');
      expect(versions.length, 1);
    });
  });

  // Covers item 6: a failed/pending_download job whose remote_path the
  // server no longer lists (quarantined, deleted, or never valid — e.g. the
  // 199 Wii NAND-blob rows on a real device, 179 of which 404'd forever)
  // must be dropped instead of retried indefinitely.
  group('pruneStaleQueueRows', () {
    test('removes a failed row whose remote_path is not in the current listing', () async {
      await syncDb.upsertState('/local/a.bin', 100, 100, 'h', 'failed',
          systemId: 'wii', remotePath: 'wii/00010008/x/content/1.app');

      final removed = await syncDb.pruneStaleQueueRows('wii', <String>{});

      expect(removed, 1);
      expect(await syncDb.getState('/local/a.bin'), isNull);
    });

    test('removes a pending_download row whose remote_path is not in the current listing', () async {
      await syncDb.upsertState('/local/b.bin', 100, 100, 'h', 'pending_download',
          systemId: 'wii', remotePath: 'wii/title/00010001/x.bin');

      final removed = await syncDb.pruneStaleQueueRows('wii', <String>{'wii/other/file.bin'});

      expect(removed, 1);
      expect(await syncDb.getState('/local/b.bin'), isNull);
    });

    test('keeps a failed/pending_download row whose remote_path is still listed', () async {
      const remotePath = 'wii/title/00010000/RSAE01/save.bin';
      await syncDb.upsertState('/local/c.bin', 100, 100, 'h', 'failed',
          systemId: 'wii', remotePath: remotePath);

      final removed = await syncDb.pruneStaleQueueRows('wii', <String>{remotePath});

      expect(removed, 0);
      expect(await syncDb.getState('/local/c.bin'), isNotNull);
    });

    test('never touches a pending_upload row, even when its remote_path is unlisted', () async {
      await syncDb.upsertState('/local/d.bin', 100, 100, 'h', 'pending_upload',
          systemId: 'wii', remotePath: 'wii/title/00010000/new_save.bin');

      final removed = await syncDb.pruneStaleQueueRows('wii', <String>{});

      expect(removed, 0);
      expect(await syncDb.getState('/local/d.bin'), isNotNull);
    });

    test('never touches a synced row, even when its remote_path is unlisted', () async {
      await syncDb.upsertState('/local/e.bin', 100, 100, 'h', 'synced',
          systemId: 'wii', remotePath: 'wii/title/00010000/old_save.bin');

      final removed = await syncDb.pruneStaleQueueRows('wii', <String>{});

      expect(removed, 0);
      expect(await syncDb.getState('/local/e.bin'), isNotNull);
    });

    test('never touches rows for a different systemId', () async {
      await syncDb.upsertState('/local/f.bin', 100, 100, 'h', 'failed',
          systemId: 'gc', remotePath: 'wii/title/00010000/f.bin');

      final removed = await syncDb.pruneStaleQueueRows('wii', <String>{});

      expect(removed, 0);
      expect(await syncDb.getState('/local/f.bin'), isNotNull);
    });

    test('also removes the row from sync_block_hashes', () async {
      await syncDb.upsertState('/local/g.bin', 100, 100, 'h', 'failed',
          systemId: 'wii', remotePath: 'wii/title/00010000/g.bin', blockHashes: '["bh1"]');

      final removed = await syncDb.pruneStaleQueueRows('wii', <String>{});

      expect(removed, 1);
      final db = await syncDb.database;
      final blockRows = await db.query('sync_block_hashes', where: 'path = ?', whereArgs: ['/local/g.bin']);
      expect(blockRows, isEmpty);
    });

    test('returns 0 without touching anything when there are no matching rows', () async {
      final removed = await syncDb.pruneStaleQueueRows('wii', <String>{});
      expect(removed, 0);
    });
  });

  // Covers the v5 migration (failed_op / failure_local_hash) that lets
  // SyncRepository.syncSystem distinguish a failed DOWNLOAD from a failed
  // upload and compare the local file's content hash against the hash
  // recorded at the moment that download failed — see
  // sync_repository_failed_download_retry_test.dart for the consumer side.
  group('failed_op / failure_local_hash (v5)', () {
    test('updateStatus(failed) records failedOp and failureLocalHash', () async {
      await syncDb.upsertState('/local/a.bin', 100, 100, 'target_hash', 'pending_download', systemId: 'switch');

      await syncDb.updateStatus('/local/a.bin', 'failed',
          error: 'HTTP 401', failedOp: 'download', failureLocalHash: 'restored_hash');

      final state = await syncDb.getState('/local/a.bin');
      expect(state, isNotNull);
      expect(state!['status'], 'failed');
      expect(state['failed_op'], 'download');
      expect(state['failure_local_hash'], 'restored_hash');
    });

    test('updateStatus(synced) always clears failedOp and failureLocalHash', () async {
      await syncDb.upsertState('/local/b.bin', 100, 100, 'target_hash', 'pending_download', systemId: 'switch');
      await syncDb.updateStatus('/local/b.bin', 'failed',
          error: 'HTTP 401', failedOp: 'download', failureLocalHash: 'restored_hash');

      await syncDb.updateStatus('/local/b.bin', 'synced');

      final state = await syncDb.getState('/local/b.bin');
      expect(state!['status'], 'synced');
      expect(state['failed_op'], isNull);
      expect(state['failure_local_hash'], isNull);
    });

    test('upsertState (INSERT OR REPLACE) clears a prior failure record on the next queue', () async {
      await syncDb.upsertState('/local/c.bin', 100, 100, 'target_hash', 'pending_download', systemId: 'switch');
      await syncDb.updateStatus('/local/c.bin', 'failed',
          error: 'HTTP 401', failedOp: 'download', failureLocalHash: 'restored_hash');

      // Requeued as a fresh pending_download after the sync-decision guard fires.
      await syncDb.upsertState('/local/c.bin', 100, 200, 'target_hash', 'pending_download', systemId: 'switch');

      final state = await syncDb.getState('/local/c.bin');
      expect(state!['status'], 'pending_download');
      expect(state['failed_op'], isNull);
      expect(state['failure_local_hash'], isNull);
    });

    test('a failed upload never carries a failureLocalHash', () async {
      await syncDb.upsertState('/local/d.bin', 100, 100, 'local_hash', 'pending_upload', systemId: 'switch');

      await syncDb.updateStatus('/local/d.bin', 'failed', error: 'HTTP 500', failedOp: 'upload');

      final state = await syncDb.getState('/local/d.bin');
      expect(state!['failed_op'], 'upload');
      expect(state['failure_local_hash'], isNull);
    });
  });
}
