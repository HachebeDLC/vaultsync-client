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
      version: 2,
      onConfigure: (db) async {
        await db.execute('PRAGMA journal_mode = WAL');
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
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute('ALTER TABLE sync_state ADD COLUMN block_hashes TEXT');
        }
      },
    );
  }

  Future<void> upsertState(String path, int size, int lastModified, String hash, String status, {String? systemId, String? remotePath, String? relPath, String? blockHashes}) async {
    final db = await database;
    await db.insert(
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

  Future<void> deleteState(String path) async {
    final db = await database;
    await db.delete('sync_state', where: 'path = ?', whereArgs: [path]);
  }

  Future<List<Map<String, dynamic>>> findEntriesByBlockHash(String blockHash) async {
    final db = await database;
    // Note: Simple JSON substring search. Efficient enough for 1MB block hashes.
    return await db.query(
      'sync_state',
      where: 'block_hashes LIKE ?',
      whereArgs: ['%$blockHash%'],
    );
  }
}
