import 'dart:io';
import 'dart:async';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class FileCache {
  static Database? _database;
  static Completer<Database>? _dbCompleter;

  Future<void> init() async {
    await database;
  }

  Future<Database> get database async {
    if (_database != null) return _database!;
    
    if (_dbCompleter != null) return _dbCompleter!.future;
    
    _dbCompleter = Completer<Database>();
    try {
      _database = await _initDatabase();
      _dbCompleter!.complete(_database!);
      return _database!;
    } catch (e) {
      final completer = _dbCompleter;
      _dbCompleter = null;
      completer?.completeError(e);
      rethrow;
    }
  }

  Future<Database> _initDatabase() async {
    String dbPath;
    if (Platform.isLinux || Platform.isWindows || Platform.isMacOS) {
      final dir = await getApplicationSupportDirectory();
      dbPath = dir.path;
    } else {
      dbPath = await getDatabasesPath();
    }
    
    final path = p.join(dbPath, 'file_cache.db');

    return await openDatabase(
      path,
      version: 2,
      onConfigure: (db) async {
        await db.execute('PRAGMA journal_mode = WAL');
        await db.execute('PRAGMA synchronous = NORMAL');
      },
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE cache(
            path TEXT PRIMARY KEY,
            size INTEGER,
            lastModified INTEGER,
            hash TEXT
          )
        ''');
        await db.execute('CREATE INDEX idx_cache_lookup ON cache (path, size, lastModified)');
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute('CREATE INDEX idx_cache_lookup ON cache (path, size, lastModified)');
        }
      },
    );
  }

  Future<void> updateCacheBatch(List<Map<String, dynamic>> entries) async {
    if (entries.isEmpty) return;
    final db = await database;
    final batch = db.batch();
    for (final entry in entries) {
      batch.insert(
        'cache',
        entry,
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
  }

  Future<String?> getCachedHash(String path, int size, int lastModified) async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query(
      'cache',
      where: 'path = ? AND size = ? AND lastModified = ?',
      whereArgs: [path, size, lastModified],
    );

    if (maps.isNotEmpty) {
      return maps.first['hash'] as String;
    }
    return null;
  }

  Future<void> updateCache(String path, int size, int lastModified, String hash) async {
    final db = await database;
    await db.insert(
      'cache',
      {
        'path': path,
        'size': size,
        'lastModified': lastModified,
        'hash': hash,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> clearCache() async {
    final db = await database;
    await db.delete('cache');
  }
}
