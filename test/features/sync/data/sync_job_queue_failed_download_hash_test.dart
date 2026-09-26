// Covers SyncJobQueue.process's permanent-failure branch: when a job finally
// gives up after 3 attempts, a failed DOWNLOAD must be recorded with
// failedOp: 'download' and the local file's current content hash (computed
// the same way the sync diff does), so SyncRepository.syncSystem's next pass
// can tell a rolled-back-but-unchanged file apart from a genuine edit (see
// sync_repository_failed_download_retry_test.dart). A failed UPLOAD must be
// recorded as failedOp: 'upload' with no content hash at all — there was no
// rollback to protect against.
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MockSyncStateDatabase mockDb;
  late MockSyncNetworkService mockNetworkService;
  late MockSystemPathService mockPathService;
  late SyncJobQueue jobQueue;

  const path = '/local/switch/MainGameSaveData';
  const remotePath = 'switch/MainGameSaveData';
  const relPath = 'MainGameSaveData';

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    mockDb = MockSyncStateDatabase();
    mockNetworkService = MockSyncNetworkService();
    mockPathService = MockSystemPathService();
    jobQueue = SyncJobQueue(mockDb, mockNetworkService, mockPathService);

    when(() => mockDb.updateStatus(any(), any(),
          error: any(named: 'error'),
          failedOp: any(named: 'failedOp'),
          failureLocalHash: any(named: 'failureLocalHash'),
        )).thenAnswer((_) async {});
    when(() => mockDb.requeueJob(any(), any(), any(), error: any(named: 'error')))
        .thenAnswer((_) async {});
  });

  Future<void> runQueue() => jobQueue.process(
        'switch',
        '/effective/path',
        (msg) {},
        getDeviceName: () async => 'TestDevice',
        recordSyncSuccess: (p, sys, rel, h, ts) {},
        getMasterKey: () async => 'master-key',
      );

  test('permanently-failed download records failedOp=download and the current local content hash', () async {
    when(() => mockDb.getPendingJobs()).thenAnswer((_) async => [
          {
            'id': 1,
            'system_id': 'switch',
            'path': path,
            'remote_path': remotePath,
            'rel_path': relPath,
            'status': 'pending_download',
            'hash': 'remote_target_hash',
            'size': 4096,
            'last_modified': 5000,
            'retry_count': 2, // this attempt is the 3rd -> permanent failure
          }
        ]);
    when(() => mockNetworkService.downloadFile(
          any(), any(), any(),
          systemId: any(named: 'systemId'),
          fileSize: any(named: 'fileSize'),
          onRecordSuccess: any(named: 'onRecordSuccess'),
          remoteHash: any(named: 'remoteHash'),
          updatedAt: any(named: 'updatedAt'),
          localUri: any(named: 'localUri'),
        )).thenThrow(Exception('Download failed: HTTP 401 Unauthorized'));
    when(() => mockNetworkService.getBlockHashesAndFileHash(path, 'master-key'))
        .thenAnswer((_) async => {'blockHashes': ['b1'], 'fileHash': 'restored-content-hash'});

    await runQueue();

    verify(() => mockDb.updateStatus(
          path, 'failed',
          error: any(named: 'error'),
          failedOp: 'download',
          failureLocalHash: 'restored-content-hash',
        )).called(1);
  });

  test('permanently-failed upload records failedOp=upload with no content hash', () async {
    when(() => mockDb.getPendingJobs()).thenAnswer((_) async => [
          {
            'id': 2,
            'system_id': 'switch',
            'path': path,
            'remote_path': remotePath,
            'rel_path': relPath,
            'status': 'pending_upload',
            'hash': 'local_hash',
            'size': 4096,
            'last_modified': 5000,
            'retry_count': 2,
          }
        ]);
    when(() => mockNetworkService.uploadFile(
          any(), any(),
          systemId: any(named: 'systemId'),
          relPath: any(named: 'relPath'),
          deviceName: any(named: 'deviceName'),
          onRecordSuccess: any(named: 'onRecordSuccess'),
          plainHash: any(named: 'plainHash'),
          localBlockHashes: any(named: 'localBlockHashes'),
          rommKey: any(named: 'rommKey'),
          rommUrl: any(named: 'rommUrl'),
          rommApiKey: any(named: 'rommApiKey'),
        )).thenThrow(Exception('Upload failed: HTTP 500'));

    await runQueue();

    verify(() => mockDb.updateStatus(
          path, 'failed',
          error: any(named: 'error'),
          failedOp: 'upload',
          failureLocalHash: null,
        )).called(1);
    // Never hashes the file for an upload failure — there was no rollback to
    // protect against, so there is nothing to compare on the next sync.
    verifyNever(() => mockNetworkService.getBlockHashesAndFileHash(any(), any()));
  });

  test('a hashing error after a failed download does not block marking it failed', () async {
    when(() => mockDb.getPendingJobs()).thenAnswer((_) async => [
          {
            'id': 3,
            'system_id': 'switch',
            'path': path,
            'remote_path': remotePath,
            'rel_path': relPath,
            'status': 'pending_download',
            'hash': 'remote_target_hash',
            'size': 4096,
            'last_modified': 5000,
            'retry_count': 2,
          }
        ]);
    when(() => mockNetworkService.downloadFile(
          any(), any(), any(),
          systemId: any(named: 'systemId'),
          fileSize: any(named: 'fileSize'),
          onRecordSuccess: any(named: 'onRecordSuccess'),
          remoteHash: any(named: 'remoteHash'),
          updatedAt: any(named: 'updatedAt'),
          localUri: any(named: 'localUri'),
        )).thenThrow(Exception('Download failed: HTTP 401 Unauthorized'));
    when(() => mockNetworkService.getBlockHashesAndFileHash(path, 'master-key'))
        .thenThrow(Exception('file vanished'));

    await runQueue();

    verify(() => mockDb.updateStatus(
          path, 'failed',
          error: any(named: 'error'),
          failedOp: 'download',
          failureLocalHash: null,
        )).called(1);
  });
}
