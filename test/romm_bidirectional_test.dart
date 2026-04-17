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

  setUp(() {
    mockDb = MockSyncStateDatabase();
    mockNetworkService = MockSyncNetworkService();
    mockPathService = MockSystemPathService();
    jobQueue = SyncJobQueue(mockDb, mockNetworkService, mockPathService);
    
    // Register fallbacks for mocktail
    registerFallbackValue('fallback_string');
  });

  group('RomM Bidirectional Integration', () {
    test('JobQueue passes RomM credentials to NetworkService during upload', () async {
      // 1. Setup mock SharedPreferences
      SharedPreferences.setMockInitialValues({
        'romm_sync_enabled': true,
        'romm_url': 'https://romm.example.com',
        'romm_api_key': 'rmm_test123',
      });
      final prefs = await SharedPreferences.getInstance();

      // 2. Setup mock DB returning a pending upload job
      when(() => mockDb.getPendingJobs()).thenAnswer((_) async => [
        {
          'id': 1,
          'system_id': 'ps2',
          'path': '/local/save.ps2',
          'remote_path': 'ps2/save.ps2',
          'rel_path': 'save.ps2',
          'status': 'pending_upload',
          'hash': 'mock_hash',
          'block_hashes': '["hash1"]',
        }
      ]);
      
      when(() => mockDb.updateStatus(any(), any(), error: any(named: 'error')))
          .thenAnswer((_) async {});
          
      // Mock requeueJob so if it fails, it doesn't crash on unmocked method
      when(() => mockDb.requeueJob(any(), any(), any(), error: any(named: 'error')))
          .thenAnswer((_) async {});

      // 3. Mock NetworkService uploadFile to succeed
      when(() => mockNetworkService.uploadFile(
        any(),
        any(),
        systemId: any(named: 'systemId'),
        relPath: any(named: 'relPath'),
        deviceName: any(named: 'deviceName'),
        onRecordSuccess: any(named: 'onRecordSuccess'),
        plainHash: any(named: 'plainHash'),
        localBlockHashes: any(named: 'localBlockHashes'),
        rommKey: any(named: 'rommKey'),
        rommUrl: any(named: 'rommUrl'),
        rommApiKey: any(named: 'rommApiKey'),
      )).thenAnswer((_) async => {});

      // 4. Execute the job queue
      await jobQueue.process(
        'ps2',
        '/local',
        (msg) {},
        getDeviceName: () async => 'TestDevice',
        recordSyncSuccess: (p, sys, rel, h, ts) {},
        getMasterKey: () async => 'mock_master_key_123',
      );

      // 5. Verify the network service received the RomM parameters!
      verify(() => mockNetworkService.uploadFile(
        '/local/save.ps2',
        'ps2/save.ps2',
        systemId: 'ps2',
        relPath: 'save.ps2',
        deviceName: 'TestDevice',
        onRecordSuccess: any(named: 'onRecordSuccess'),
        plainHash: 'mock_hash',
        localBlockHashes: ['hash1'],
        rommKey: 'mock_master_key_123',
        rommUrl: 'https://romm.example.com',
        rommApiKey: 'rmm_test123',
      )).called(1);
    });

    test('JobQueue executes download process for pending download job', () async {
      SharedPreferences.setMockInitialValues({});
      
      // Setup mock DB returning a pending download job
      when(() => mockDb.getPendingJobs()).thenAnswer((_) async => [
        {
          'id': 2,
          'system_id': 'ps2',
          'path': '/local/save.ps2',
          'remote_path': 'ps2/save.ps2',
          'rel_path': 'save.ps2',
          'status': 'pending_download',
          'hash': 'mock_hash_romm_pulled',
          'size': 2048,
          'last_modified': 2000000,
        }
      ]);
      
      when(() => mockDb.updateStatus(any(), any(), error: any(named: 'error')))
          .thenAnswer((_) async {});
          
      when(() => mockDb.upsertState(
          any(), any(), any(), any(), any(),
          systemId: any(named: 'systemId'),
          remotePath: any(named: 'remotePath'),
          relPath: any(named: 'relPath'),
        )).thenAnswer((_) async {});

      // Mock NetworkService downloadFileNative to succeed
      when(() => mockNetworkService.downloadFile(
        any(), any(), any(),
        systemId: any(named: 'systemId'),
        fileSize: any(named: 'fileSize'),
        onRecordSuccess: any(named: 'onRecordSuccess'),
        remoteHash: any(named: 'remoteHash'),
        updatedAt: any(named: 'updatedAt'),
        localUri: any(named: 'localUri'),
      )).thenAnswer((_) async {
        return {
          'size': 2048,
          'lastModified': 2000000,
        };
      });

      // Execute the job queue
      await jobQueue.process(
        'ps2',
        '/local',
        (msg) {},
        getDeviceName: () async => 'TestDevice',
        recordSyncSuccess: (p, sys, rel, h, ts) {},
        getMasterKey: () async => 'mock_master_key_123',
      );

      // Verify the network service downloaded the file correctly
      verify(() => mockNetworkService.downloadFile(
        'ps2/save.ps2', '/local', 'save.ps2',
        systemId: 'ps2',
        fileSize: 2048,
        onRecordSuccess: any(named: 'onRecordSuccess'),
        remoteHash: 'mock_hash_romm_pulled',
        updatedAt: 2000000,
        localUri: '/local/save.ps2',
      )).called(1);
      
      // Verify upsertState was called to set the status to synced
      verify(() => mockDb.upsertState(
        '/local/save.ps2', 2048, 2000000, 'mock_hash_romm_pulled', 'synced',
        systemId: 'ps2', remotePath: 'ps2/save.ps2', relPath: 'save.ps2'
      )).called(1);
    });
  });
}
