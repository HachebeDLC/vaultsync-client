// Regression coverage for the zero-size scan metadata guard in the
// `localInfo != null && remoteInfo != null` branch of SyncRepository.syncSystem.
//
// Background: the SAF cursor's COLUMN_SIZE can report 0 for a file that
// actually has real content (confirmed on-device: a 4012-byte Switch save
// scanned as 0 bytes). Before this guard, a stale DB-cached row + a stale
// sync journal entry recorded from an earlier (also-corrupted) scan could
// both agree with a 0-byte remote copy and skip the file entirely, via the
// `isJournaledSynced` shortcut or the "DB-cached synced" shortcut — neither
// of which reads actual file content. These tests exercise the full
// syncSystem() both-exist branch (rather than a hand-extracted pure
// function) because the interaction between the two shortcuts, the
// zero-size gate, and the hash-cache bypass is exactly what regressed on
// the real device, and SyncRepository's constructor-injected mocks make
// that reachable without real I/O.
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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
import 'package:vaultsync_client/features/sync/services/local_versioning_service.dart';

class MockApiClient extends Mock implements ApiClient {}
class MockSystemPathService extends Mock implements SystemPathService {}
class MockFileCache extends Mock implements FileCache {}
class MockSyncNetworkService extends Mock implements SyncNetworkService {}
class MockSyncPathResolver extends Mock implements SyncPathResolver {}
class MockSyncStateDatabase extends Mock implements SyncStateDatabase {}
class MockFileHashService extends Mock implements FileHashService {}
class MockConflictResolver extends Mock implements ConflictResolver {}
class MockSwitchProfileResolver extends Mock implements SwitchProfileResolver {}
class MockSyncDiffService extends Mock implements SyncDiffService {}
class MockSyncJobQueue extends Mock implements SyncJobQueue {}
class MockLocalVersioningService extends Mock implements LocalVersioningService {}
class _FakeSharedPreferences extends Fake implements SharedPreferences {}

/// SyncRepository's snapshot step calls `_ref?.read(localVersioningServiceProvider)`,
/// which needs a real [Ref], not a mock. This top-level provider is only a way to
/// pull a genuine Ref out of a ProviderContainer that overrides
/// [localVersioningServiceProvider] with our mock.
final _refCaptureProvider = Provider<Ref>((ref) => ref);

// The app's double-SHA-256 of empty input — the hash the production server
// found on 18 zero-byte saves. Used here purely as an opaque "this is what
// an empty file hashes to" token; tests never compute it.
const String kEmptyHash = '5df6e0e2761359d30a8275058e299fcc0381534545f55cf43e41983f5d4c9456';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    registerFallbackValue((SharedPreferences p, String s1, String s2, String s3, {int? localTs}) => false);
    registerFallbackValue((SharedPreferences p, String s1, String s2, String s3, [int? ts]) {});
    registerFallbackValue((String s1, String s2, List<String>? l) async => []);
    registerFallbackValue(_FakeSharedPreferences());
  });

  const systemId = 'ps2';
  const localPath = '/storage/emulated/0/PS2';
  const relPath = 'save1.dat';
  const localUri = 'content://test/save1.dat';
  const remotePath = 'ps2/save1.dat';
  const staleTs = 1700000000000; // the (wrong) mtime the corrupted SAF scan reports

  late MockApiClient mockApiClient;
  late MockSystemPathService mockPathService;
  late MockFileCache mockFileCache;
  late MockSyncNetworkService mockNetworkService;
  late MockSyncPathResolver mockPathResolver;
  late MockSyncStateDatabase mockSyncStateDb;
  late MockFileHashService mockFileHashService;
  late MockConflictResolver mockConflictResolver;
  late MockSwitchProfileResolver mockSwitchResolver;
  late MockSyncDiffService mockDiffService;
  late MockSyncJobQueue mockJobQueue;
  late MockLocalVersioningService mockVersioningService;
  late ProviderContainer container;
  late SyncRepository repository;

  setUp(() {
    SharedPreferences.setMockInitialValues({});

    mockApiClient = MockApiClient();
    mockPathService = MockSystemPathService();
    mockFileCache = MockFileCache();
    mockNetworkService = MockSyncNetworkService();
    mockPathResolver = MockSyncPathResolver();
    mockSyncStateDb = MockSyncStateDatabase();
    mockFileHashService = MockFileHashService();
    mockConflictResolver = MockConflictResolver();
    mockSwitchResolver = MockSwitchProfileResolver();
    mockDiffService = MockSyncDiffService();
    mockJobQueue = MockSyncJobQueue();
    mockVersioningService = MockLocalVersioningService();

    container = ProviderContainer(overrides: [
      localVersioningServiceProvider.overrideWithValue(mockVersioningService),
    ]);
    final ref = container.read(_refCaptureProvider);

    repository = SyncRepository(
      mockApiClient, mockPathService, mockFileCache, mockNetworkService,
      mockPathResolver, mockSyncStateDb, mockFileHashService, mockConflictResolver,
      mockSwitchResolver, mockDiffService, mockJobQueue, ref,
    );

    when(() => mockPathService.getEffectivePath(any())).thenAnswer((_) async => localPath);
    when(() => mockPathService.pathExists(any())).thenAnswer((_) async => true);
    when(() => mockPathService.mkdirs(any())).thenAnswer((_) async => true);
    when(() => mockApiClient.getEncryptionKey()).thenAnswer((_) async => 'master-key');
    when(() => mockJobQueue.process(any(), any(), any(),
      getDeviceName: any(named: 'getDeviceName'),
      recordSyncSuccess: any(named: 'recordSyncSuccess'),
      getMasterKey: any(named: 'getMasterKey'),
      isCancelled: any(named: 'isCancelled'),
    )).thenAnswer((_) async {});
    when(() => mockSyncStateDb.upsertState(any(), any(), any(), any(), any(),
      systemId: any(named: 'systemId'),
      remotePath: any(named: 'remotePath'),
      relPath: any(named: 'relPath'),
      blockHashes: any(named: 'blockHashes'),
    )).thenAnswer((_) async {});
    when(() => mockVersioningService.createSnapshot(any(), any(), any(),
      masterKey: any(named: 'masterKey'),
      currentBlockHashes: any(named: 'currentBlockHashes'),
      currentFileHash: any(named: 'currentFileHash'),
    )).thenAnswer((_) async => 'snap-1');
  });

  tearDown(() {
    container.dispose();
  });

  group('zero-size scan metadata guard (both-exist branch)', () {
    test('(a) stale 0B scan + matching journal/DB row, but real content is NOT empty -> queued for upload', () async {
      when(() => mockConflictResolver.processLocalFiles(any(), any())).thenReturn({
        relPath: {'uri': localUri, 'lastModified': staleTs, 'size': 0, 'originalRelPath': relPath},
      });
      when(() => mockDiffService.fetchAllRemoteFiles(any())).thenAnswer((_) async => [
        {'path': remotePath, 'hash': kEmptyHash, 'size': 0, 'updated_at': staleTs},
      ]);
      // DB cache row: 0 bytes, old ts, previously marked synced with the empty hash.
      when(() => mockSyncStateDb.getState(localUri)).thenAnswer((_) async => {
        'size': 0, 'last_modified': staleTs, 'status': 'synced', 'hash': kEmptyHash, 'block_hashes': null,
      });
      // Journal also agrees with the (stale) empty hash.
      when(() => mockConflictResolver.isJournaledSynced(any(), any(), any(), any(), localTs: any(named: 'localTs')))
          .thenReturn(true);
      // The real file content hashes to something other than the empty hash.
      const realHash = 'real-content-hash-nonempty';
      when(() => mockNetworkService.getBlockHashesAndFileHash(localUri, 'master-key'))
          .thenAnswer((_) async => {'blockHashes': ['b1'], 'fileHash': realHash});

      await repository.syncSystem(systemId, localPath, ignoreConnectivity: true);

      // The zero-size gate must bypass the (size, ts)-keyed hash cache entirely —
      // it is keyed on the same untrustworthy size and could hand back a stale
      // cached hash for this exact (uri, 0, staleTs) combination.
      verifyNever(() => mockFileHashService.getCachedHash(any(), any(), any()));
      verifyNever(() => mockFileHashService.getLocalHash(any(), any(), any(), precomputedHash: any(named: 'precomputedHash')));

      verify(() => mockSyncStateDb.upsertState(
        localUri, 0, staleTs, realHash, 'pending_upload',
        systemId: systemId, remotePath: remotePath, relPath: relPath, blockHashes: any(named: 'blockHashes'),
      )).called(1);
    });

    test('(d) empty cloud copy newer than a non-empty local file -> never queued for download', () async {
      final olderLocalTs = staleTs - 86400000;
      when(() => mockConflictResolver.processLocalFiles(any(), any())).thenReturn({
        relPath: {'uri': localUri, 'lastModified': olderLocalTs, 'size': 4052, 'originalRelPath': relPath},
      });
      when(() => mockDiffService.fetchAllRemoteFiles(any())).thenAnswer((_) async => [
        {'path': remotePath, 'hash': kEmptyHash, 'size': 0, 'updated_at': staleTs},
      ]);
      when(() => mockSyncStateDb.getState(localUri)).thenAnswer((_) async => null);
      when(() => mockNetworkService.getBlockHashesAndFileHash(localUri, 'master-key'))
          .thenAnswer((_) async => {'blockHashes': ['b1'], 'fileHash': 'real-content-hash-nonempty'});
      final errors = <String>[];

      await repository.syncSystem(systemId, localPath, ignoreConnectivity: true, onError: errors.add);

      verifyNever(() => mockSyncStateDb.upsertState(any(), any(), any(), any(), 'pending_download',
        systemId: any(named: 'systemId'), remotePath: any(named: 'remotePath'),
        relPath: any(named: 'relPath'), blockHashes: any(named: 'blockHashes')));
      expect(errors.single, contains('cloud copy is empty'));
    });

    test('(b) stale 0B scan + matching journal/DB row, and real content IS empty -> marked synced, no upload', () async {
      when(() => mockConflictResolver.processLocalFiles(any(), any())).thenReturn({
        relPath: {'uri': localUri, 'lastModified': staleTs, 'size': 0, 'originalRelPath': relPath},
      });
      when(() => mockDiffService.fetchAllRemoteFiles(any())).thenAnswer((_) async => [
        {'path': remotePath, 'hash': kEmptyHash, 'size': 0, 'updated_at': staleTs},
      ]);
      when(() => mockSyncStateDb.getState(localUri)).thenAnswer((_) async => {
        'size': 0, 'last_modified': staleTs, 'status': 'synced', 'hash': kEmptyHash, 'block_hashes': null,
      });
      when(() => mockConflictResolver.isJournaledSynced(any(), any(), any(), any(), localTs: any(named: 'localTs')))
          .thenReturn(true);
      // The real file genuinely is empty, so its actual content hash is the empty hash.
      when(() => mockNetworkService.getBlockHashesAndFileHash(localUri, 'master-key'))
          .thenAnswer((_) async => {'blockHashes': ['b1'], 'fileHash': kEmptyHash});

      await repository.syncSystem(systemId, localPath, ignoreConnectivity: true);

      verifyNever(() => mockFileHashService.getCachedHash(any(), any(), any()));
      verifyNever(() => mockVersioningService.createSnapshot(any(), any(), any(),
        masterKey: any(named: 'masterKey'),
        currentBlockHashes: any(named: 'currentBlockHashes'),
        currentFileHash: any(named: 'currentFileHash'),
      ));

      verify(() => mockSyncStateDb.upsertState(
        localUri, 0, staleTs, kEmptyHash, 'synced',
        systemId: systemId, remotePath: remotePath, relPath: relPath, blockHashes: any(named: 'blockHashes'),
      )).called(1);

      verifyNever(() => mockSyncStateDb.upsertState(
        any(), any(), any(), any(), 'pending_upload',
        systemId: any(named: 'systemId'), remotePath: any(named: 'remotePath'),
        relPath: any(named: 'relPath'), blockHashes: any(named: 'blockHashes'),
      ));
    });

    test('(c) normal non-empty unchanged file still takes the journal shortcut (no hashing, no regression)', () async {
      const nonEmptyRelPath = 'save2.dat';
      const nonEmptyUri = 'content://test/save2.dat';
      const nonEmptyRemotePath = 'ps2/save2.dat';
      const nonEmptyHash = 'abc123';

      when(() => mockConflictResolver.processLocalFiles(any(), any())).thenReturn({
        nonEmptyRelPath: {'uri': nonEmptyUri, 'lastModified': staleTs, 'size': 500, 'originalRelPath': nonEmptyRelPath},
      });
      when(() => mockDiffService.fetchAllRemoteFiles(any())).thenAnswer((_) async => [
        {'path': nonEmptyRemotePath, 'hash': nonEmptyHash, 'size': 500, 'updated_at': staleTs},
      ]);
      when(() => mockSyncStateDb.getState(nonEmptyUri)).thenAnswer((_) async => {
        'size': 500, 'last_modified': staleTs, 'status': 'synced', 'hash': nonEmptyHash, 'block_hashes': null,
      });
      when(() => mockConflictResolver.isJournaledSynced(any(), any(), any(), any(), localTs: any(named: 'localTs')))
          .thenReturn(true);

      await repository.syncSystem(systemId, localPath, ignoreConnectivity: true);

      // No hashing of any kind should occur for the common unchanged, non-empty case.
      verifyNever(() => mockNetworkService.getBlockHashesAndFileHash(any(), any()));
      verifyNever(() => mockFileHashService.getCachedHash(any(), any(), any()));
      verifyNever(() => mockFileHashService.getLocalHash(any(), any(), any(), precomputedHash: any(named: 'precomputedHash')));
      // The journal shortcut just `continue`s — no DB write at all for this file.
      verifyNever(() => mockSyncStateDb.upsertState(
        any(), any(), any(), any(), any(),
        systemId: any(named: 'systemId'), remotePath: any(named: 'remotePath'),
        relPath: any(named: 'relPath'), blockHashes: any(named: 'blockHashes'),
      ));
    });
  });
}
