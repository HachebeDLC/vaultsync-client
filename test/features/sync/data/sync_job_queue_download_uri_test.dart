import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vaultsync_client/features/sync/data/sync_job_queue.dart';
import 'package:vaultsync_client/features/sync/data/sync_state_database.dart';
import 'package:vaultsync_client/features/sync/services/sync_network_service.dart';
import 'package:vaultsync_client/features/sync/services/system_path_service.dart';

class MockSyncStateDatabase extends Mock implements SyncStateDatabase {}

class MockSyncNetworkService extends Mock implements SyncNetworkService {}

class MockSystemPathService extends Mock implements SystemPathService {}

/// Covers the post-download state-key fixup in [SyncJobQueue.process]:
///
/// A remote-only download is queued under a synthetic `path` —
/// `p.join(effectivePath, destRelPath)` — that the native SAF scanner can
/// never emit as a real document URI (see SyncRepository.syncSystem's
/// download branch). Native's `downloadFileNative` now returns the canonical
/// URI it actually resolved the file to (DownloadManager.handleDownloadFile),
/// and the queue must move the state row there so the next sync's
/// `getState(scannedUri)` lookup finds it instead of treating the file as
/// never-synced forever.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MockSyncStateDatabase mockDb;
  late MockSyncNetworkService mockNetworkService;
  late MockSystemPathService mockPathService;
  late SyncJobQueue jobQueue;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    mockDb = MockSyncStateDatabase();
    mockNetworkService = MockSyncNetworkService();
    mockPathService = MockSystemPathService();
    jobQueue = SyncJobQueue(mockDb, mockNetworkService, mockPathService);

    when(() => mockDb.updateStatus(any(), any(), error: any(named: 'error')))
        .thenAnswer((_) async {});
    when(() => mockDb.requeueJob(any(), any(), any(), error: any(named: 'error')))
        .thenAnswer((_) async {});
    when(() => mockDb.upsertState(
          any(), any(), any(), any(), any(),
          systemId: any(named: 'systemId'),
          remotePath: any(named: 'remotePath'),
          relPath: any(named: 'relPath'),
        )).thenAnswer((_) async {});
    when(() => mockDb.deleteState(any())).thenAnswer((_) async {});
  });

  const syntheticPath = 'content://com.android.externalstorage.documents/tree/'
      'primary%3AAndroid%2Fdata%2Fdev.eden.eden_emulator/nand/user/save/'
      '0000000000000000/deadbeef/rep_gamedata1.dat';
  const canonicalUri = 'content://com.android.externalstorage.documents/tree/'
      'primary%3AAndroid%2Fdata%2Fdev.eden.eden_emulator/document/'
      'primary%3AAndroid%2Fdata%2Fdev.eden.eden_emulator%2Fnand%2Fuser%2Fsave%2F'
      '0000000000000000%2Fdeadbeef%2Frep_gamedata1.dat';

  void stubPendingDownloadJob() {
    when(() => mockDb.getPendingJobs()).thenAnswer((_) async => [
          {
            'id': 1,
            'system_id': 'switch',
            'path': syntheticPath,
            'remote_path': 'switch/rep_gamedata1.dat',
            'rel_path': 'rep_gamedata1.dat',
            'status': 'pending_download',
            'hash': 'remote_hash',
            'size': 4012,
            'last_modified': 5000,
          }
        ]);
  }

  Future<void> runQueue() => jobQueue.process(
        'switch',
        '/effective/path',
        (msg) {},
        getDeviceName: () async => 'TestDevice',
        recordSyncSuccess: (p, sys, rel, h, ts) {},
        getMasterKey: () async => null,
      );

  test('download result with a differing canonical uri moves the state row', () async {
    stubPendingDownloadJob();
    when(() => mockNetworkService.downloadFile(
          any(), any(), any(),
          systemId: any(named: 'systemId'),
          fileSize: any(named: 'fileSize'),
          onRecordSuccess: any(named: 'onRecordSuccess'),
          remoteHash: any(named: 'remoteHash'),
          updatedAt: any(named: 'updatedAt'),
          localUri: any(named: 'localUri'),
        )).thenAnswer((_) async => {
          'size': 4012,
          'lastModified': 5000,
          'uri': canonicalUri,
        });

    await runQueue();

    // The row is written under the canonical (scanner-matching) URI …
    verify(() => mockDb.upsertState(
          canonicalUri, 4012, 5000, 'remote_hash', 'synced',
          systemId: 'switch', remotePath: 'switch/rep_gamedata1.dat', relPath: 'rep_gamedata1.dat',
        )).called(1);
    // … the synthetic row it was queued under is removed …
    verify(() => mockDb.deleteState(syntheticPath)).called(1);
    // … it is never (re)written under the synthetic path …
    verifyNever(() => mockDb.upsertState(
          syntheticPath, any(), any(), any(), any(),
          systemId: any(named: 'systemId'),
          remotePath: any(named: 'remotePath'),
          relPath: any(named: 'relPath'),
        ));
    // … and the final status flip does not resurrect the deleted synthetic row.
    verifyNever(() => mockDb.updateStatus(syntheticPath, 'synced', error: any(named: 'error')));
  });

  test('download result without a uri keeps writing under the job path', () async {
    stubPendingDownloadJob();
    when(() => mockNetworkService.downloadFile(
          any(), any(), any(),
          systemId: any(named: 'systemId'),
          fileSize: any(named: 'fileSize'),
          onRecordSuccess: any(named: 'onRecordSuccess'),
          remoteHash: any(named: 'remoteHash'),
          updatedAt: any(named: 'updatedAt'),
          localUri: any(named: 'localUri'),
        )).thenAnswer((_) async => {
          'size': 4012,
          'lastModified': 5000,
          // No 'uri' key: desktop DartNativeCrypto fallback / old native build.
        });

    await runQueue();

    verify(() => mockDb.upsertState(
          syntheticPath, 4012, 5000, 'remote_hash', 'synced',
          systemId: 'switch', remotePath: 'switch/rep_gamedata1.dat', relPath: 'rep_gamedata1.dat',
        )).called(1);
    verifyNever(() => mockDb.deleteState(any()));
    verify(() => mockDb.updateStatus(syntheticPath, 'synced', error: any(named: 'error'))).called(1);
  });

  test('download result whose uri equals the job path is treated as unchanged', () async {
    stubPendingDownloadJob();
    when(() => mockNetworkService.downloadFile(
          any(), any(), any(),
          systemId: any(named: 'systemId'),
          fileSize: any(named: 'fileSize'),
          onRecordSuccess: any(named: 'onRecordSuccess'),
          remoteHash: any(named: 'remoteHash'),
          updatedAt: any(named: 'updatedAt'),
          localUri: any(named: 'localUri'),
        )).thenAnswer((_) async => {
          'size': 4012,
          'lastModified': 5000,
          'uri': syntheticPath,
        });

    await runQueue();

    verify(() => mockDb.upsertState(
          syntheticPath, 4012, 5000, 'remote_hash', 'synced',
          systemId: 'switch', remotePath: 'switch/rep_gamedata1.dat', relPath: 'rep_gamedata1.dat',
        )).called(1);
    verifyNever(() => mockDb.deleteState(any()));
  });
}
