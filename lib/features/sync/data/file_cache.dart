import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;

class FileCache {
  static Database? _database;

  Future<void> init() async {
    await database;
  }

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  Future<Database> _initDatabase() async {
    final dbPath = await getDatabasesPath();
    final path = p.join(dbPath, 'file_cache.db');

    return await openDatabase(
      path,
      version: 2,
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
