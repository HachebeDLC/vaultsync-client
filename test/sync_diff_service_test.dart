import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:vaultsync_client/features/sync/data/sync_diff_service.dart';
import 'package:vaultsync_client/core/services/api_client.dart';
import 'package:vaultsync_client/features/sync/services/conflict_resolver.dart';
import 'package:vaultsync_client/features/sync/data/sync_state_database.dart';
import 'package:vaultsync_client/features/sync/services/sync_path_resolver.dart';
import 'package:shared_preferences/shared_preferences.dart';

class MockApiClient extends Mock implements ApiClient {}
class MockConflictResolver extends Mock implements ConflictResolver {}
class MockSyncStateDatabase extends Mock implements SyncStateDatabase {}
class MockSyncPathResolver extends Mock implements SyncPathResolver {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SyncDiffService diffService;
  late MockApiClient mockApiClient;
  late MockConflictResolver mockConflictResolver;
  late MockSyncStateDatabase mockSyncStateDb;
  late MockSyncPathResolver mockPathResolver;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    mockApiClient = MockApiClient();
    mockConflictResolver = MockConflictResolver();
    mockSyncStateDb = MockSyncStateDatabase();
    mockPathResolver = MockSyncPathResolver();
    diffService = SyncDiffService(
      mockApiClient,
      mockConflictResolver,
      mockSyncStateDb,
      mockPathResolver,
    );
  });

  group('SyncDiffService Offline Handling', () {
    test('diffSystem should return local files with Modified/Local Only status when offline/network fails', () async {
      when(() => mockApiClient.get(any(), queryParams: any(named: 'queryParams')))
          .thenThrow(Exception('Network error'));
      when(() => mockConflictResolver.processLocalFiles(any(), any()))
          .thenReturn({
        'save1.sav': {
          'uri': '/local/save1.sav',
          'size': 100,
          'lastModified': 123456789,
          'relPath': 'save1.sav'
        }
      });
      when(() => mockConflictResolver.sortResults(any())).thenAnswer((inv) => inv.positionalArguments[0] as List<Map<String, dynamic>>);
      when(() => mockSyncStateDb.getState(any())).thenAnswer((_) async => null);

      final results = await diffService.diffSystem(
        'ps2',
        '/roms/ps2',
        effectivePath: '/roms/ps2',
        getCachedOrNewScan: (sys, path, ignore, [saveExts]) async => ['/local/save1.sav'],
        isJournaledSynced: (prefs, sys, rel, hash, {localTs}) => false,
        recordSyncSuccess: (prefs, sys, rel, hash, [ts]) {},
      );

      expect(results.length, 1);
      expect(results.first['status'], 'Local Only');
    });
  });

  group('Wii NAND blob exclusion (item 5)', () {
    test('diffSystem excludes .app/.tmd/.wad NAND blobs from the results', () async {
      when(() => mockApiClient.get(any(), queryParams: any(named: 'queryParams')))
          .thenAnswer((_) async => {
                'files': [
                  {
                    'path': 'wii/00010008/00000002/content/0000001c.app',
                    'size': 10,
                    'updated_at': 1000,
                    'hash': 'h1',
                  },
                  {
                    'path': 'wii/title/00010000/RSAE01/data01.bin',
                    'size': 20,
                    'updated_at': 2000,
                    'hash': 'h2',
                  },
                ],
                'next_cursor': null,
              });
      when(() => mockConflictResolver.processLocalFiles(any(), any())).thenReturn({});
      when(() => mockConflictResolver.sortResults(any()))
          .thenAnswer((inv) => inv.positionalArguments[0] as List<Map<String, dynamic>>);
      when(() => mockSyncStateDb.getState(any())).thenAnswer((_) async => null);

      final results = await diffService.diffSystem(
        'wii',
        '/roms/wii',
        effectivePath: '/roms/wii',
        getCachedOrNewScan: (sys, path, ignore, [saveExts]) async => [],
        isJournaledSynced: (prefs, sys, rel, hash, {localTs}) => false,
        recordSyncSuccess: (prefs, sys, rel, hash, [ts]) {},
      );

      expect(results.length, 1);
      expect(results.first['relPath'], 'title/00010000/RSAE01/data01.bin');
      expect(results.first['status'], 'Remote Only');
    });
  });
}