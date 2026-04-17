import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vaultsync_client/features/sync/data/sync_repository.dart';
import 'package:vaultsync_client/features/sync/data/switch_profile_resolver.dart';
import 'package:vaultsync_client/features/sync/data/sync_diff_service.dart';
import 'package:vaultsync_client/features/sync/data/sync_job_queue.dart';
import 'package:vaultsync_client/features/sync/services/system_path_service.dart';
import 'package:vaultsync_client/features/sync/data/file_cache.dart';
import 'package:vaultsync_client/core/services/api_client.dart';
import 'package:vaultsync_client/features/sync/services/sync_network_service.dart';
import 'package:vaultsync_client/features/sync/services/sync_path_resolver.dart';
import 'package:vaultsync_client/features/sync/data/sync_state_database.dart';
import 'package:vaultsync_client/features/sync/services/file_hash_service.dart';
import 'package:vaultsync_client/features/sync/services/conflict_resolver.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class MockApiClient extends Mock implements ApiClient {}
class MockSystemPathService extends Mock implements SystemPathService {}
class MockSyncNetworkService extends Mock implements SyncNetworkService {}
class MockSyncPathResolver extends Mock implements SyncPathResolver {}
class MockSyncStateDatabase extends Mock implements SyncStateDatabase {}
class MockFileHashService extends Mock implements FileHashService {}
class MockConflictResolver extends Mock implements ConflictResolver {}
class MockSwitchProfileResolver extends Mock implements SwitchProfileResolver {}
class MockSyncDiffService extends Mock implements SyncDiffService {}
class MockSyncJobQueue extends Mock implements SyncJobQueue {}
class FakeSharedPreferences extends Fake implements SharedPreferences {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  
  setUpAll(() {
    registerFallbackValue(FakeSharedPreferences());
  });

  // Use FFI for sqflite in tests
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late SyncRepository repository;
  late MockSyncPathResolver mockPathResolver;
  late MockConflictResolver mockConflictResolver;
  late MockSyncStateDatabase mockSyncStateDb;
  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();

    // Setup in-memory DB for FileCache
    final db = await openDatabase(
      inMemoryDatabasePath,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE cache(
            path TEXT PRIMARY KEY,
            size INTEGER,
            lastModified INTEGER,
            hash TEXT
          )
        ''');
      },
    );
    FileCache.setDatabase(db);
    
    mockPathResolver = MockSyncPathResolver();
    mockConflictResolver = MockConflictResolver();
    mockSyncStateDb = MockSyncStateDatabase();
    
    repository = SyncRepository(
      MockApiClient(),
      MockSystemPathService(),
      FileCache(), // Use real FileCache for testing logic
      MockSyncNetworkService(),
      mockPathResolver,
      mockSyncStateDb,
      MockFileHashService(),
      mockConflictResolver,
      MockSwitchProfileResolver(),
      MockSyncDiffService(),
      MockSyncJobQueue(),
      null,
    );

    // Mock ConflictResolver's isJournaledSynced to return false by default
    when(() => mockConflictResolver.isJournaledSynced(any(), any(), any(), any(), localTs: any(named: 'localTs')))
        .thenReturn(false);
  });

  group('Fuzzy Timestamp Logic', () {
    test('Journaling should ignore sub-second differences', () async {
      const systemId = 'retroarch';
      const relPath = 'saves/game.srm';
      const hash = 'abc123hash';
      const timestampMs = 1712760000500; // 12:00:00.500
      const jitterMs = 1712760000100;    // 12:00:00.100 (diff is 400ms)

      // 1. Record success with high-precision timestamp
      repository.recordSyncSuccess(prefs, systemId, relPath, hash, timestampMs);

      // 2. Check if synced using a slightly different timestamp
      final isSynced = repository.isJournaledSynced(prefs, systemId, relPath, hash);

      expect(isSynced, true, reason: 'Sync engine should treat sub-second jitter as the same second');
    });

    test('Identity unification should handle casing', () async {
      const relPath = 'saves/game.srm';
      const hash = 'abc123hash';
      const timestampMs = 1712760000000;

      // Record as lowercase 'retroarch'
      repository.recordSyncSuccess(prefs, 'retroarch', relPath, hash, timestampMs);

      // Check as uppercase 'RetroArch'
      final isSynced = repository.isJournaledSynced(prefs, 'RetroArch', relPath, hash);

      expect(isSynced, true, reason: 'Journal should be case-insensitive for systemId');
    });
  });

  group('FileCache Fuzzy Logic', () {
    test('Cache lookup should be resilient to sub-second jitter', () async {
      final cache = FileCache();
      const path = '/test/save.srm';
      const size = 1024;
      const ts = 1712760000800; // .800
      const jitterTs = 1712760000200; // .200
      const hash = 'hash-value';

      await cache.updateCache(path, size, ts, hash);
      
      final cachedHash = await cache.getCachedHash(path, size, jitterTs);
      
      expect(cachedHash, equals(hash), reason: 'File cache must find the hash even if timestamp drifted by < 1s');
    });
  });
}
