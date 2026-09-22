import 'dart:convert';
import 'dart:io';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class SyncStateDatabase {
  Database? _database;
  final String? dbPathOverride;

  SyncStateDatabase({this.dbPathOverride});

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  Future<Database> _initDatabase() async {
    String dbPath;
    if (dbPathOverride != null) {
      dbPath = dbPathOverride!;
    } else if (Platform.isLinux || Platform.isWindows || Platform.isMacOS) {
      final dir = await getApplicationSupportDirectory();
      dbPath = p.join(dir.path, 'sync_state.db');
    } else {
      final dir = await getDatabasesPath();
      dbPath = p.join(dir, 'sync_state.db');
    }

    return await openDatabase(
      dbPath,
      version: 4,
      onConfigure: (db) async {
        await db.rawQuery('PRAGMA journal_mode = WAL');
        await db.execute('PRAGMA synchronous = NORMAL');
      },
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE sync_state(
            path TEXT PRIMARY KEY,
            size INTEGER,
            last_modified INTEGER,
            hash TEXT,
            status TEXT,
            system_id TEXT,
            remote_path TEXT,
            rel_path TEXT,
            error TEXT,
            block_hashes TEXT,
            retry_count INTEGER DEFAULT 0
          )
        ''');
        await db.execute('CREATE INDEX idx_sync_status ON sync_state (status)');
        await db.execute('''
          CREATE TABLE sync_block_hashes(
            path TEXT NOT NULL,
            block_hash TEXT NOT NULL,
            PRIMARY KEY (path, block_hash)
          )
        ''');
        await db.execute('CREATE INDEX idx_block_hash ON sync_block_hashes (block_hash)');
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
        await db.execute('CREATE INDEX idx_versions_system_file ON local_versions (systemId, filePath)');
        await db.execute('''
          CREATE TABLE version_blocks(
            versionId TEXT NOT NULL,
            blockIndex INTEGER NOT NULL,
            blockHash TEXT NOT NULL,
            PRIMARY KEY (versionId, blockIndex),
            FOREIGN KEY (versionId) REFERENCES local_versions(id) ON DELETE CASCADE
          )
        ''');
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute('ALTER TABLE sync_state ADD COLUMN block_hashes TEXT');
        }
        if (oldVersion < 3) {
          await db.execute('''
            CREATE TABLE IF NOT EXISTS sync_block_hashes(
              path TEXT NOT NULL,
              block_hash TEXT NOT NULL,
              PRIMARY KEY (path, block_hash)
            )
          ''');
          await db.execute('CREATE INDEX IF NOT EXISTS idx_block_hash ON sync_block_hashes (block_hash)');
        }
        if (oldVersion < 4) {
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
          await db.execute('CREATE INDEX idx_versions_system_file ON local_versions (systemId, filePath)');
          await db.execute('''
            CREATE TABLE version_blocks(
              versionId TEXT NOT NULL,
              blockIndex INTEGER NOT NULL,
              blockHash TEXT NOT NULL,
              PRIMARY KEY (versionId, blockIndex),
              FOREIGN KEY (versionId) REFERENCES local_versions(id) ON DELETE CASCADE
            )
          ''');
        }
      },
    );
  }

  Future<void> upsertState(String path, int size, int lastModified, String hash, String status, {String? systemId, String? remotePath, String? relPath, String? blockHashes}) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.insert(
        'sync_state',
        {
          'path': path,
          'size': size,
          'last_modified': lastModified,
          'hash': hash,
          'status': status,
          'system_id': systemId,
          'remote_path': remotePath,
          'rel_path': relPath,
          'block_hashes': blockHashes,
          'retry_count': 0,
          'error': null,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

      await txn.delete('sync_block_hashes', where: 'path = ?', whereArgs: [path]);
      if (blockHashes != null && blockHashes.isNotEmpty) {
        final List<String> hashes = List<String>.from(jsonDecode(blockHashes));
        for (final bh in hashes) {
          await txn.insert(
            'sync_block_hashes',
            {'path': path, 'block_hash': bh},
            conflictAlgorithm: ConflictAlgorithm.ignore,
          );
        }
      }
    });
  }

  Future<Map<String, dynamic>?> getState(String path) async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      'sync_state',
      where: 'path = ?',
      whereArgs: [path],
    );
    if (maps.isNotEmpty) return maps.first;
    return null;
  }

  Future<List<Map<String, dynamic>>> getPendingJobs() async {
    final db = await database;
    return await db.query(
      'sync_state',
      where: 'status IN (?, ?)',
      whereArgs: ['pending_upload', 'pending_download'],
    );
  }

  Future<List<Map<String, dynamic>>> getPendingOfflineJobs() async {
    final db = await database;
    return await db.query(
      'sync_state',
      where: 'status IN (?, ?)',
      whereArgs: ['pending_offline_upload', 'pending_offline_download'],
    );
  }

  Future<void> markOfflineJobsAsPending() async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.update(
        'sync_state',
        {'status': 'pending_upload'},
        where: 'status = ?',
        whereArgs: ['pending_offline_upload'],
      );
      await txn.update(
        'sync_state',
        {'status': 'pending_download'},
        where: 'status = ?',
        whereArgs: ['pending_offline_download'],
      );
    });
  }

  Future<void> updateStatus(String path, String status, {String? error}) async {
    final db = await database;
    await db.update(
      'sync_state',
      {
        'status': status,
        'error': error,
        'retry_count': status == 'failed' ? 1 : 0,
      },
      where: 'path = ?',
      whereArgs: [path],
    );
  }

  Future<void> requeueJob(String path, String status, int retryCount, {String? error}) async {
    final db = await database;
    await db.update(
      'sync_state',
      {'status': status, 'retry_count': retryCount, 'error': error},
      where: 'path = ?',
      whereArgs: [path],
    );
  }

  Future<void> deleteState(String path) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete('sync_block_hashes', where: 'path = ?', whereArgs: [path]);
      await txn.delete('sync_state', where: 'path = ?', whereArgs: [path]);
    });
  }

  /// Extracts the SAF tree-root segment from a `content://.../tree/<root>...`
  /// URI (the part between `/tree/` and the next `/`, or the end of the
  /// string). Returns null when [uri] has no `/tree/` segment. Kept as plain
  /// substring work rather than a SQL `LIKE` pattern: the segment is
  /// percent-encoded (e.g. `primary%3AAndroid%2Fdata%2F...`), and embedding a
  /// literal `%` in a `LIKE` pattern turns it into a wildcard, not a match.
  static String? _treeRootOf(String uri) {
    const marker = '/tree/';
    final idx = uri.indexOf(marker);
    if (idx == -1) return null;
    final after = uri.substring(idx + marker.length);
    final slash = after.indexOf('/');
    return slash == -1 ? after : after.substring(0, slash);
  }

  /// Deletes dead `sync_state` rows for [systemId] left behind by two known
  /// causes, both harmless to lose because they can never be re-matched by a
  /// future scan and status is 'synced' (real work, not a queued job):
  ///
  ///  (a) "tree+path" shaped rows: a `content://` URI containing `/tree/` but
  ///      not `/document/`. The only source of this shape was the download
  ///      branch keying state by `p.join(effectivePath, destRelPath)` instead
  ///      of the URI the native downloader actually wrote to — `FileScanner`
  ///      never emits this shape, so the row can never be looked up again.
  ///
  ///  (b) `content://` rows whose SAF tree root differs from
  ///      [effectivePath]'s tree root — left over from an earlier SAF grant
  ///      for the same system (e.g. a stale
  ///      `.../Android%2Fdata%2Fdev.eden.eden_emulator%2Ffiles` grant after
  ///      the user re-granted `.../Android%2Fdata%2Fdev.eden.eden_emulator`).
  ///
  /// Rows with any other status (pending/failed) are never touched — they are
  /// real queued work the native side can still act on. `local_versions` is
  /// untouched. Returns the number of rows removed.
  Future<int> cleanupDeadContentUriRows(String systemId, String effectivePath) async {
    final db = await database;
    final rows = await db.query(
      'sync_state',
      columns: ['path'],
      where: 'system_id = ? AND status = ? AND path LIKE ?',
      whereArgs: [systemId, 'synced', 'content://%'],
    );
    if (rows.isEmpty) return 0;

    final currentTreeRoot = _treeRootOf(effectivePath);
    final deadPaths = <String>[];
    for (final row in rows) {
      final path = row['path'] as String;
      final hasTree = path.contains('/tree/');
      if (!hasTree) continue;
      final hasDocument = path.contains('/document/');
      final isTreePathShaped = !hasDocument;
      final isStaleRoot = hasDocument &&
          currentTreeRoot != null &&
          _treeRootOf(path) != currentTreeRoot;
      if (isTreePathShaped || isStaleRoot) deadPaths.add(path);
    }
    if (deadPaths.isEmpty) return 0;

    final placeholders = List.filled(deadPaths.length, '?').join(',');
    await db.transaction((txn) async {
      await txn.delete('sync_block_hashes', where: 'path IN ($placeholders)', whereArgs: deadPaths);
      await txn.delete('sync_state', where: 'path IN ($placeholders)', whereArgs: deadPaths);
    });
    return deadPaths.length;
  }

  Future<List<Map<String, dynamic>>> findEntriesByBlockHash(String blockHash) async {
    final db = await database;
    return await db.rawQuery(
      'SELECT s.* FROM sync_state s '
      'INNER JOIN sync_block_hashes b ON s.path = b.path '
      'WHERE b.block_hash = ?',
      [blockHash],
    );
  }
}
