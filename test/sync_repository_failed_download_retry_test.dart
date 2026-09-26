// Covers the "both exist" branch of SyncRepository.syncSystem when the cached
// row is a permanently-FAILED download (see SyncJobQueue.process, which now
// records `failed_op` + `failure_local_hash` on that terminal failure).
//
// Background (real device, POCO F8 Pro, Android 16): a native download of a
// newer remote save failed (stale 401 token) and rolled back to the previous
// local bytes. The rollback's file write stamped mtime to "now", which made
// the OLDER, rolled-back local file look newer than the server copy on the
// very next sync — so syncSystem took the "Local Newer" branch and uploaded
// the stale save straight over the user's good remote copy.
//
// The fix: when the cached row says the last attempt was a failed download
// AND the local file's current content hash still matches the hash recorded
// at that failure (i.e. nothing really changed, the mtime bump is just the
// rollback), treat it as cloud-still-newer and retry the download — never
// upload. If the content HAS changed since the failure (the user genuinely
// played), the existing mtime-based decision applies normally.
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

final _refCaptureProvider = Provider<Ref>((ref) => ref);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    registerFallbackValue((SharedPreferences p, String s1, String s2, String s3, {int? localTs}) => false);
    registerFallbackValue((SharedPreferences p, String s1, String s2, String s3, [int? ts]) {});
    registerFallbackValue((String s1, String s2, List<String>? l) async => []);
    registerFallbackValue(_FakeSharedPreferences());
  });

  const systemId = 'switch';
  const localPath = '/storage/emulated/0/Switch';
  const relPath = 'MainGameSaveData';
  const localUri = 'content://test/MainGameSaveData';
  const remotePath = 'switch/MainGameSaveData';
  // Remote is genuinely older in wall-clock terms than the rolled-back local
  // file's mtime — this is exactly what made the old code pick "Local Newer".
  const remoteTs = 1700000000000;
  const localTsAfterRollback = remoteTs + 12000; // rollback happened ~12s later
  const failureLocalHash = 'hash-of-the-restored-old-save';
  const remoteHash = 'hash-of-the-good-server-save';

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

    when(() => mockConflictResolver.processLocalFiles(any(), any())).thenReturn({
      relPath: {
        'uri': localUri,
        'lastModified': localTsAfterRollback,
        'size': 4096,
        'originalRelPath': relPath,
      },
    });
    when(() => mockDiffService.fetchAllRemoteFiles(any())).thenAnswer((_) async => [
      {'path': remotePath, 'hash': remoteHash, 'size': 4096, 'updated_at': remoteTs},
    ]);
    // Not the 'synced' fast paths, so isJournaledSynced/getCachedHash must not
    // short-circuit past the real hash comparison.
    when(() => mockConflictResolver.isJournaledSynced(any(), any(), any(), any(), localTs: any(named: 'localTs')))
        .thenReturn(false);
    when(() => mockFileHashService.getCachedHash(any(), any(), any())).thenAnswer((_) async => null);
    when(() => mockFileHashService.getLocalHash(any(), any(), any(), precomputedHash: any(named: 'precomputedHash')))
        .thenAnswer((invocation) async => invocation.namedArguments[#precomputedHash] as String);
    // systemId 'switch' routes _getCachedOrNewScan's raw scan result through
    // SwitchProfileResolver.applyProfileFixes — pass it through unchanged.
    when(() => mockSwitchResolver.applyProfileFixes(any(), any()))
        .thenAnswer((invocation) async => invocation.positionalArguments[0] as List<dynamic>);
  });

  tearDown(() {
    container.dispose();
  });

  test('(i) failed download + unchanged local content -> re-queued as a download, never an upload', () async {
    when(() => mockSyncStateDb.getState(localUri)).thenAnswer((_) async => {
      'status': 'failed',
      'failed_op': 'download',
      'failure_local_hash': failureLocalHash,
      'hash': 'stale-target-hash',
      'size': 4096,
      'last_modified': localTsAfterRollback,
      'block_hashes': null,
    });
    // The local file's content hasn't actually changed since the failed
    // download — it still hashes to what was recorded at failure time.
    when(() => mockNetworkService.getBlockHashesAndFileHash(localUri, 'master-key'))
        .thenAnswer((_) async => {'blockHashes': ['b1'], 'fileHash': failureLocalHash});

    await repository.syncSystem(systemId, localPath, ignoreConnectivity: true);

    verify(() => mockSyncStateDb.upsertState(
      localUri, 4096, remoteTs, remoteHash, 'pending_download',
      systemId: systemId, remotePath: remotePath, relPath: relPath,
      blockHashes: any(named: 'blockHashes'),
    )).called(1);

    verifyNever(() => mockSyncStateDb.upsertState(
      any(), any(), any(), any(), 'pending_upload',
      systemId: any(named: 'systemId'), remotePath: any(named: 'remotePath'),
      relPath: any(named: 'relPath'), blockHashes: any(named: 'blockHashes'),
    ));
  });

  test('(ii) failed download + changed local content -> normal local-newer upload applies', () async {
    when(() => mockSyncStateDb.getState(localUri)).thenAnswer((_) async => {
      'status': 'failed',
      'failed_op': 'download',
      'failure_local_hash': failureLocalHash,
      'hash': 'stale-target-hash',
      'size': 4096,
      'last_modified': localTsAfterRollback,
      'block_hashes': null,
    });
    // The user genuinely played again while the download kept failing: the
    // real content hash today differs from the one recorded at failure time.
    const changedHash = 'hash-of-a-genuinely-new-save';
    when(() => mockNetworkService.getBlockHashesAndFileHash(localUri, 'master-key'))
        .thenAnswer((_) async => {'blockHashes': ['b2'], 'fileHash': changedHash});

    await repository.syncSystem(systemId, localPath, ignoreConnectivity: true);

    // localTsAfterRollback > remoteTs, so the ordinary mtime-based decision
    // applies and this is queued as a normal upload.
    verify(() => mockSyncStateDb.upsertState(
      localUri, 4096, localTsAfterRollback, changedHash, 'pending_upload',
      systemId: systemId, remotePath: remotePath, relPath: relPath,
      blockHashes: any(named: 'blockHashes'),
    )).called(1);

    verifyNever(() => mockSyncStateDb.upsertState(
      any(), any(), any(), any(), 'pending_download',
      systemId: any(named: 'systemId'), remotePath: any(named: 'remotePath'),
      relPath: any(named: 'relPath'), blockHashes: any(named: 'blockHashes'),
    ));
  });

  test('a failed UPLOAD row (not a download) never triggers the retry-download guard', () async {
    when(() => mockSyncStateDb.getState(localUri)).thenAnswer((_) async => {
      'status': 'failed',
      'failed_op': 'upload',
      'failure_local_hash': null,
      'hash': 'stale-target-hash',
      'size': 4096,
      'last_modified': localTsAfterRollback,
      'block_hashes': null,
    });
    when(() => mockNetworkService.getBlockHashesAndFileHash(localUri, 'master-key'))
        .thenAnswer((_) async => {'blockHashes': ['b3'], 'fileHash': 'whatever-current-hash'});

    await repository.syncSystem(systemId, localPath, ignoreConnectivity: true);

    // Ordinary mtime-based decision: local is newer, so normal upload.
    verify(() => mockSyncStateDb.upsertState(
      localUri, 4096, localTsAfterRollback, 'whatever-current-hash', 'pending_upload',
      systemId: systemId, remotePath: remotePath, relPath: relPath,
      blockHashes: any(named: 'blockHashes'),
    )).called(1);
  });
}
