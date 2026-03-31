import 'dart:convert';
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mutex/mutex.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:crypto/crypto.dart';
import 'package:meta/meta.dart';
import 'file_cache.dart';
import 'dart_file_scanner.dart';
import 'dart_native_crypto.dart';
import 'sync_state_database.dart';
import '../domain/notification_models.dart';
import '../domain/notification_provider.dart';
import '../services/sync_network_service.dart';
import '../services/sync_path_resolver.dart';
import '../services/system_path_service.dart';
import '../../../core/services/api_client.dart';
import '../../../core/services/api_client_provider.dart';

import '../services/file_hash_service.dart';
import '../services/conflict_resolver.dart';
import '../services/notification_service.dart';
import '../services/power_manager_service.dart';

final syncPathResolverProvider = Provider<SyncPathResolver>((ref) => SyncPathResolver());
final syncStateDatabaseProvider = Provider<SyncStateDatabase>((ref) => SyncStateDatabase());

final fileHashServiceProvider = Provider<FileHashService>((ref) {
  return FileHashService(FileCache());
});

final conflictResolverProvider = Provider<ConflictResolver>((ref) {
  final pathResolver = ref.watch(syncPathResolverProvider);
  return ConflictResolver(pathResolver);
});

final notificationServiceProvider = Provider<NotificationService>((ref) {
  return NotificationService();
});

final powerManagerServiceProvider = Provider<PowerManagerService>((ref) {
  return PowerManagerService();
});

final syncNetworkServiceProvider = Provider<SyncNetworkService>((ref) {
  final apiClient = ref.watch(apiClientProvider);
  return SyncNetworkService(apiClient);
});

final syncRepositoryProvider = Provider<SyncRepository>((ref) {
  final apiClient = ref.watch(apiClientProvider);
  final pathService = ref.watch(systemPathServiceProvider);
  final networkService = ref.watch(syncNetworkServiceProvider);
  final pathResolver = ref.watch(syncPathResolverProvider);
  final syncStateDb = ref.watch(syncStateDatabaseProvider);
  final hashService = ref.watch(fileHashServiceProvider);
  final conflictResolver = ref.watch(conflictResolverProvider);
  return SyncRepository(apiClient, pathService, FileCache(), networkService, pathResolver, syncStateDb, hashService, conflictResolver, ref);
});

/// Repository responsible for orchestrating the synchronization of emulator save data
/// between the local filesystem and the VaultSync server.
class SyncRepository {
  final ApiClient _apiClient;
  final SystemPathService _pathService;
  final FileCache _fileCache;
  final SyncNetworkService _networkService;
  final SyncPathResolver _pathResolver;
  final SyncStateDatabase _syncStateDb;
  final FileHashService _hashService;
  final ConflictResolver _conflictResolver;
  final Ref? _ref;
  static const _platform = MethodChannel('com.vaultsync.app/launcher');
  final _syncLock = Mutex();

  String? _cachedDeviceName;
  List<dynamic> _lastScanList = [];

  SyncRepository(this._apiClient, this._pathService, this._fileCache, this._networkService, this._pathResolver, this._syncStateDb, this._hashService, this._conflictResolver, [this._ref]);

  Future<String> _getDeviceName() async => getDeviceNameInternal();

  @visibleForTesting
  Future<String> getDeviceNameInternal() async {
    if (_cachedDeviceName != null) return _cachedDeviceName!;

    final deviceInfo = DeviceInfoPlugin();
    if (Platform.isAndroid) {
      final androidInfo = await deviceInfo.androidInfo;
      _cachedDeviceName = androidInfo.model;
    } else if (Platform.isWindows) {
      final windowsInfo = await deviceInfo.windowsInfo;
      _cachedDeviceName = windowsInfo.computerName;
    } else if (Platform.isLinux) {
      final linuxInfo = await deviceInfo.linuxInfo;
      _cachedDeviceName = linuxInfo.prettyName;
    }
    return _cachedDeviceName ?? 'Unknown Device';
  }

  final Map<String, String> _pendingJournal = {};

  void _recordSyncSuccess(SharedPreferences prefs, String systemId, String relPath, String hash) {
    _pendingJournal['journal_${systemId}_$relPath'] = hash;
  }

  Future<void> _commitSyncJournal(SharedPreferences prefs) async {
    if (_pendingJournal.isEmpty) return;
    await Future.wait(_pendingJournal.entries.map((e) => prefs.setString(e.key, e.value)));
    _pendingJournal.clear();
  }

  bool _isJournaledSynced(SharedPreferences prefs, String systemId, String relPath, String remoteHash) {
    final key = 'journal_${systemId}_$relPath';
    if (_pendingJournal.containsKey(key)) return _pendingJournal[key] == remoteHash;
    return _conflictResolver.isJournaledSynced(prefs, systemId, relPath, remoteHash);
  }

  final Map<String, (List<dynamic>, DateTime)> _scanCache = {};
  static const _scanCacheTTL = Duration(seconds: 30);

  Future<List<dynamic>> _getCachedOrNewScan(String systemId, String effectivePath, List<String>? ignoredFolders) async {
    final cacheKey = '${systemId}_$effectivePath';
    final cached = _scanCache[cacheKey];
    if (cached != null && DateTime.now().difference(cached.$2) < _scanCacheTTL) {
       _lastScanList = cached.$1;
       return _lastScanList;
    }
    
    List<dynamic> result = [];
    try {
      if (Platform.isLinux || Platform.isWindows || Platform.isMacOS) {
        result = await DartFileScanner.scanRecursive(effectivePath, systemId, ignoredFolders ?? []);
      } else {
        final String jsonResult = await _platform.invokeMethod('scanRecursive', { 'path': effectivePath, 'systemId': systemId, 'ignoredFolders': ignoredFolders ?? [] });
        result = json.decode(jsonResult);
      }
    } catch (e) {
      print('⚠️ SCAN: Path does not exist or inaccessible: $effectivePath ($e)');
      // For Switch/Eden on a fresh install, the save folder might not exist yet.
      // We continue so the probeProfileId logic can still try to find the profile ID
      // by walking the parent directory tree.
    }

    // For Switch/Eden: ALWAYS probe profiles.dat for the authoritative profile ID.
    // We cannot rely on the scan alone — a previous buggy sync may have created a
    // wrong (e.g. byte-reversed) profile folder that the scan then perpetuates.
    final sid = systemId.toLowerCase();
    if (sid == 'switch' || sid == 'eden') {
      final profileRegex = RegExp(r'^[0-9A-Fa-f]{32}$');
      final probed = await _pathService.probeProfileId(effectivePath);

      if (probed != null) {
        // Remove any scan entries that contain a DIFFERENT 32-char profile ID under
        // nand/user/save/0000000000000000/ — those are stale/wrong folders.
        result = result.where((f) {
          final path = (f['relPath'] as String?) ?? '';
          if (!path.contains('nand/user/save/0000000000000000/')) return true;
          final segments = path.split('/');
          final zeroIdx = segments.indexOf('0000000000000000');
          if (zeroIdx != -1 && zeroIdx + 1 < segments.length) {
            final candidate = segments[zeroIdx + 1];
            if (profileRegex.hasMatch(candidate) && candidate != probed) {
              print('🎮 SWITCH: Dropping stale/wrong profile ID from scan: $candidate (authoritative: $probed)');
              return false;
            }
          }
          return true;
        }).toList();

        // Inject the correct profile ID entry if not already present.
        final hasCorrectId = result.any((f) {
          final path = (f['relPath'] as String?) ?? '';
          return path.contains('nand/user/save/0000000000000000/$probed');
        });
        if (!hasCorrectId) {
          result = List.from(result)..add({
            'relPath': 'nand/user/save/0000000000000000/$probed',
            'name': probed,
            'isDirectory': true,
            'uri': '',
            'size': 0,
            'lastModified': 0,
          });
          print('🎮 SWITCH: Injected authoritative profile ID: $probed');
        } else {
          print('🎮 SWITCH: Authoritative profile ID confirmed from scan: $probed');
        }
      } else {
        // Probe failed — fall back to whatever the scan found.
        final hasAnyProfileId = result.any((f) {
          final path = (f['relPath'] as String?) ?? '';
          return path.contains('nand/user/save') &&
                 path.split('/').any((s) => profileRegex.hasMatch(s) && s != '00000000000000000000000000000000');
        });
        if (!hasAnyProfileId) {
          print('🎮 SWITCH: No profile ID found from probe or scan — downloads will use zeros placeholder.');
        }
      }
    }

    _lastScanList = result;
    _scanCache[cacheKey] = (result, DateTime.now());
    return result;
  }

  Future<List<Map<String, dynamic>>> diffSystem(String systemId, String localPath, {List<String>? ignoredFolders}) async {
    final prefs = await SharedPreferences.getInstance();
    final effectivePath = await _pathService.getEffectivePath(systemId);
    
    // Ensure base path exists so scanner doesn't fail
    await _pathService.mkdirs(effectivePath);

    final sid = systemId.toLowerCase();
    final isSwitch = sid == 'eden' || sid == 'switch';
    final response = await _apiClient.get('/api/v1/files', queryParams: {'prefix': isSwitch ? 'switch' : (localPath.toLowerCase().contains('retroarch') ? 'RetroArch' : systemId)});
    final List<dynamic> allRemoteFiles = response['files'] ?? [];

    final remoteFilesList = allRemoteFiles.where((f) {
      final path = f['path'] as String;
      final rel = path.contains('/') ? path.split('/').skip(1).join('/') : path;
      final firstSegment = rel.split('/').first.toLowerCase();
      if (isSwitch) {
         final isTitleId = RegExp(r'^[0-9A-Fa-f]{16}$').hasMatch(firstSegment);
         final isSystemPath = ['nand', 'config', 'files', 'gpu_drivers'].contains(firstSegment);
         return isTitleId && !isSystemPath;
      }
      if (sid == '3ds' || sid == 'azahar') return rel.startsWith('saves/');
      return true;
    }).toList();

    final String cloudPrefix = isSwitch ? 'switch' : (localPath.toLowerCase().contains('retroarch') ? 'RetroArch' : systemId);
    final remoteFiles = { for (var f in remoteFilesList) f['path']: f };
    final List<dynamic> localList = await _getCachedOrNewScan(systemId, effectivePath, ignoredFolders);
    final localFiles = _conflictResolver.processLocalFiles(systemId, localList);

    final Set<String> cloudRelPaths = { ...localFiles.keys, ...remoteFiles.keys.map((p) => p.substring(cloudPrefix.length + 1)) };
    final List<Map<String, dynamic>> results = [];

    for (final relPath in cloudRelPaths) {
      if (relPath.isEmpty) continue;
      String remotePath = '$cloudPrefix/$relPath';
      final localInfo = localFiles[relPath];
      final remoteInfo = remoteFiles[remotePath];
      String status = 'Synced';
      String type = (relPath.toLowerCase().contains('.state') || relPath.toLowerCase().endsWith('.png')) ? 'State' : 'Save';
      
      if (localInfo == null) status = 'Remote Only';
      else if (remoteInfo == null) status = 'Local Only';
      else {
        final String remoteHash = remoteInfo['hash'];
        if (_isJournaledSynced(prefs, systemId, relPath, remoteHash)) status = 'Synced';
        else {
          // Check SQLite cache for a more robust verify
          final cached = await _syncStateDb.getState(localInfo['uri']);
          final int localTs = (localInfo['lastModified'] as num).toInt();
          final int localSize = (localInfo['size'] as num).toInt();
          
          if (cached != null && 
              cached['size'] == localSize && 
              (cached['last_modified'] ~/ 1000) == (localTs ~/ 1000) && 
              cached['hash'] == remoteHash) {
            status = 'Synced';
            // Proactively update journal so we skip checking DB next time
            _recordSyncSuccess(prefs, systemId, relPath, remoteHash);
          } else {
            // Fallback to loose server-timestamp match if not in DB
            final int remoteTs = (remoteInfo['updated_at'] as num).toInt() ~/ 1000;
            if (localInfo['size'] != remoteInfo['size'] || (localTs ~/ 1000) != remoteTs) {
              status = 'Modified';
            }
          }
        }
      }
      results.add({ 'relPath': relPath, 'remotePath': remotePath, 'status': status, 'type': type, 'localInfo': localInfo, 'remoteInfo': remoteInfo, 'isDirectory': false, 'name': relPath.split('/').last });
    }
    return _conflictResolver.sortResults(results);
  }

  Future<void> syncSystem(String systemId, String localPath, {List<String>? ignoredFolders, Function(String)? onProgress, Function(String)? onError, String? filenameFilter, bool fastSync = false, bool Function()? isCancelled}) async {
    await _syncLock.protect(() async {
      final prefs = await SharedPreferences.getInstance();
      final effectivePath = await _pathService.getEffectivePath(systemId);

      // Ensure the base path exists. For Switch/Eden on fresh install,
      // we might need to create the 'save' directory.
      await _pathService.mkdirs(effectivePath);

      final String cloudPrefix = (systemId.toLowerCase() == 'eden') ? 'switch' : (localPath.toLowerCase().contains('retroarch') ? 'RetroArch' : systemId);
      
      try {
        final response = await _apiClient.get('/api/v1/files', queryParams: {'prefix': cloudPrefix});
        final List<dynamic> fileList = response['files'] ?? [];
        final remoteFiles = { for (var f in fileList) f['path']: f };
        final List<dynamic> localList = await _getCachedOrNewScan(systemId, effectivePath, ignoredFolders);
        final localFiles = _conflictResolver.processLocalFiles(systemId, localList);
        final Set<String> cloudRelPaths = { ...localFiles.keys, ...remoteFiles.keys.map((p) => p.substring(cloudPrefix.length + 1)) };

        for (final relPath in cloudRelPaths) {
          if (isCancelled?.call() == true) { onProgress?.call('Sync Cancelled'); break; }
          if (relPath.isEmpty) continue;
          final remotePath = '$cloudPrefix/$relPath';
          if (filenameFilter != null && !remotePath.contains(filenameFilter)) continue;
          final localInfo = localFiles[relPath];
          final remoteInfo = remoteFiles[remotePath];

          if (localInfo != null && remoteInfo == null) {
            final int localTs = (localInfo['lastModified'] as num).toInt();
            final int localSize = (localInfo['size'] as num).toInt();
            final cached = await _syncStateDb.getState(localInfo['uri']);
            if (cached != null && cached['size'] == localSize && cached['last_modified'] == localTs && cached['status'] == 'synced') {
               await _syncStateDb.upsertState(localInfo['uri'], localSize, localTs, cached['hash'], 'pending_upload', systemId: systemId, remotePath: remotePath, relPath: relPath, blockHashes: cached['block_hashes']);
            } else {
               onProgress?.call('Hashing $relPath...');
               final masterKey = await _getMasterKey();
               final blockHashes = await _networkService.getBlockHashes(localInfo['uri'], masterKey);
               final fullHash = await _hashService.getLocalHash(localInfo['uri'], localSize, localTs);
               await _syncStateDb.upsertState(localInfo['uri'], localSize, localTs, fullHash, 'pending_upload', systemId: systemId, remotePath: remotePath, relPath: relPath, blockHashes: json.encode(blockHashes));
            }
          } else if (localInfo == null && remoteInfo != null) {
            onProgress?.call('Queueing $relPath for download...');
            final destRelPath = _pathResolver.getLocalRelPath(systemId, relPath, localFiles, _lastScanList);
            final destUri = p.join(effectivePath, destRelPath);
            print('📂 SYNC: Queueing Switch download: $relPath -> $destUri (Base: $effectivePath)');
            await _syncStateDb.upsertState(destUri, remoteInfo['size'], remoteInfo['updated_at'], remoteInfo['hash'], 'pending_download', systemId: systemId, remotePath: remotePath, relPath: destRelPath);
          } else if (localInfo != null && remoteInfo != null) {
            final String remoteHash = remoteInfo['hash'];
            final int localTs = (localInfo['lastModified'] as num).toInt();
            final int localSize = (localInfo['size'] as num).toInt();
            if (_isJournaledSynced(prefs, systemId, relPath, remoteHash)) continue;
            
            final cached = await _syncStateDb.getState(localInfo['uri']);
            if (cached != null && cached['size'] == localSize && (cached['last_modified'] ~/ 1000) == (localTs ~/ 1000) && cached['hash'] == remoteHash && cached['status'] == 'synced') {
               _recordSyncSuccess(prefs, systemId, relPath, remoteHash);
               continue;
            }
            onProgress?.call('Checking $relPath blocks...');
            final masterKey = await _getMasterKey();
            final currentBlockHashes = await _networkService.getBlockHashes(localInfo['uri'], masterKey);
            final String localHash = await _hashService.getLocalHash(localInfo['uri'], localSize, localTs);

            if (localHash == remoteHash) { 
              await _syncStateDb.upsertState(localInfo['uri'], localSize, localTs, localHash, 'synced', systemId: systemId, remotePath: remotePath, relPath: relPath, blockHashes: json.encode(currentBlockHashes));
              _recordSyncSuccess(prefs, systemId, relPath, remoteHash); 
              continue; 
            }
            if (localTs > (remoteInfo['updated_at'] as num)) {
              onProgress?.call('Queueing $relPath for patching (Local Newer)...');
              await _syncStateDb.upsertState(localInfo['uri'], localSize, localTs, localHash, 'pending_upload', systemId: systemId, remotePath: remotePath, relPath: relPath, blockHashes: json.encode(currentBlockHashes));
            } else {
              onProgress?.call('Queueing $relPath for patching (Cloud Newer)...');
              await _syncStateDb.upsertState(localInfo['uri'], localSize, localTs, localHash, 'pending_download', systemId: systemId, remotePath: remotePath, relPath: relPath, blockHashes: json.encode(currentBlockHashes));
            }
          }
        }
        await _processJobQueue(systemId, effectivePath, onProgress);
        await _commitSyncJournal(prefs);
      } catch (e) { 
        print('❌ SYNC ERROR: $e'); 
        _ref?.read(notificationLogProvider.notifier).addError(e, systemId: systemId);
        onError?.call(e.toString()); 
        rethrow; 
      } 
    });
  }

  Future<void> _processJobQueue(String systemId, String effectivePath, Function(String)? onProgress) async {
    final jobs = await _syncStateDb.getPendingJobs();
    final prefs = await SharedPreferences.getInstance();
    for (final job in jobs) {
      if (job['system_id'] != systemId) continue;
      final path = job['path'];
      final status = job['status'];
      final remotePath = job['remote_path'];
      final relPath = job['rel_path'];
      final blockHashesJson = job['block_hashes'] as String?;
      final List<String>? blockHashes = blockHashesJson != null ? List<String>.from(json.decode(blockHashesJson)) : null;

      try {
        if (status == 'pending_upload') {
           onProgress?.call('Uploading ${relPath?.split("/").last ?? path.split("/").last}...');
           await uploadFile(path, remotePath!, systemId: systemId, relPath: relPath!, prefs: prefs, plainHash: job['hash'], localBlockHashes: blockHashes);
        } else if (status == 'pending_download') {
           onProgress?.call('Downloading ${relPath?.split("/").last ?? path.split("/").last}...');
           final downloadResult = await downloadFile(remotePath!, effectivePath, relPath!, systemId: systemId, prefs: prefs, fileSize: job['size'], remoteHash: job['hash'], localUri: path, updatedAt: (job['last_modified'] as num?)?.toInt());
           
           // CRITICAL: After download, we MUST update the DB with the ACTUAL file info
           // from the disk (size/timestamp) so the next scan matches exactly.
           // We now use the metadata returned directly from the native download call.
           if (downloadResult is Map) {
              await _syncStateDb.upsertState(
                path, 
                (downloadResult['size'] as num).toInt(), 
                (downloadResult['lastModified'] as num).toInt(), 
                job['hash'], 
                'synced',
                systemId: systemId,
                remotePath: remotePath,
                relPath: relPath
              );
           } else {
             // Fallback for desktop or older native code
             try {
               final info = await _platform.invokeMapMethod('getFileInfo', {'uri': path});
               if (info != null) {
                 await _syncStateDb.upsertState(
                   path, 
                   (info['size'] as num).toInt(), 
                   (info['lastModified'] as num).toInt(), 
                   job['hash'], 
                   'synced',
                   systemId: systemId,
                   remotePath: remotePath,
                   relPath: relPath
                 );
               }
             } catch (e) {
               print('⚠️ Failed to update post-download metadata for $path: $e');
             }
           }
        }
        await _syncStateDb.updateStatus(path, 'synced');
      } catch (e) { 
        print('⚠️ Job failed for $path: $e'); 
        _ref?.read(notificationLogProvider.notifier).addError(e, systemId: systemId);
        await _syncStateDb.updateStatus(path, 'failed', error: e.toString()); 
      }
    }
  }

  Future<void> processManualQueue() async {
    final jobs = await _syncStateDb.getPendingJobs();
    for (final job in jobs) {
       final systemId = job['system_id'];
       if (systemId == null) continue;
       final effectivePath = await _pathService.getEffectivePath(systemId);
       await _processJobQueue(systemId, effectivePath, (msg) => print('Queue: $msg'));
    }
  }

  Future<void> uploadFile(dynamic localPathOrFile, String remotePath, {required String systemId, required String relPath, required SharedPreferences prefs, String? plainHash, List<String>? localBlockHashes, bool force = false}) async {
    final path = localPathOrFile is File ? localPathOrFile.path : localPathOrFile.toString();
    await _networkService.uploadFile(path, remotePath, systemId: systemId, relPath: relPath, deviceName: await _getDeviceName(), onRecordSuccess: (sid, rp, h) => _recordSyncSuccess(prefs, sid, rp, h), plainHash: plainHash, localBlockHashes: localBlockHashes, force: force);
  }

  Future<dynamic> downloadFile(String remotePath, String localBasePath, String relPath, {required String systemId, required SharedPreferences prefs, required int fileSize, String? remoteHash, int? updatedAt, dynamic serverBlocks, String? localUri}) async {
    return await _networkService.downloadFile(remotePath, localBasePath, relPath, systemId: systemId, fileSize: fileSize, onRecordSuccess: (sid, rp, h) => _recordSyncSuccess(prefs, sid, rp, h), remoteHash: remoteHash, updatedAt: updatedAt, serverBlocks: serverBlocks, localUri: localUri);
  }

  Future<void> deleteRemoteFile(String path) async { await _apiClient.delete('/api/v1/files', body: {'filename': path}); }
  Future<List<Map<String, dynamic>>> getFileVersions(String remotePath) async { final response = await _apiClient.get('/api/v1/versions?path=$remotePath'); return List<Map<String, dynamic>>.from(response['versions'] ?? []); }
  Future<void> restoreVersion(String remotePath, String versionId, String localBasePath, String relPath, int fileSize) async { await _networkService.restoreVersion(remotePath, versionId, localBasePath, relPath, fileSize); }
  Future<void> deleteSystemCloudData(String systemId) async { await _apiClient.delete('/api/v1/systems/$systemId'); }
  Future<List<Map<String, dynamic>>> getAllRemoteConflicts() async { try { final response = await _apiClient.get('/api/v1/conflicts'); return List<Map<String, dynamic>>.from(response['conflicts'] ?? []); } catch(_) { return []; } }

  Future<String> _getLocalHash(String uri, int size, int lastModified) async {
    return await _hashService.getLocalHash(uri, size, lastModified);
  }

  Future<String?> _getMasterKey() async {
     return await _apiClient.getEncryptionKey();
  }

  Future<Map<String, dynamic>> scanLocalFiles(String path, String systemId) async {
    List<dynamic> list;
    if (Platform.isLinux || Platform.isWindows || Platform.isMacOS) list = await DartFileScanner.scanRecursive(path, systemId, []);
    else { final String result = await _platform.invokeMethod('scanRecursive', {'path': path, 'systemId': systemId}); list = json.decode(result); }
    return _conflictResolver.processLocalFiles(systemId, list);
  }

  Future<bool> _tryLocalBlockRecovery(String targetPath, int targetIndex, String blockHash, int blockSize) async {
    final sources = await _syncStateDb.findEntriesByBlockHash(blockHash);
    for (final source in sources) {
       final sourcePath = source['path'];
       if (sourcePath == targetPath) continue;
       if (!await File(sourcePath).exists()) continue;
       final sourceHashes = List<String>.from(json.decode(source['block_hashes']));
       final sourceIndex = sourceHashes.indexOf(blockHash);
       if (sourceIndex == -1) continue;
       try {
         final sourceFile = File(sourcePath);
         final sourceRaf = await sourceFile.open(mode: FileMode.read);
         await sourceRaf.setPosition(sourceIndex * blockSize);
         final blockData = await sourceRaf.read(blockSize);
         await sourceRaf.close();
         if (sha256.convert(blockData).toString() == blockHash) {
            final targetFile = File(targetPath);
            final targetRaf = await targetFile.open(mode: FileMode.append);
            await targetRaf.setPosition(targetIndex * blockSize);
            await targetRaf.writeFrom(blockData);
            await targetRaf.close();
            print('♻️ DEDUPE: Recovered block $blockHash from $sourcePath');
            return true;
         }
       } catch (e) { print('⚠️ DEDUPE: Failed to recover block from $sourcePath: $e'); }
    }
    return false;
  }

  Future<void> handleRemoteEvent(Map<String, dynamic> data) async {
    final String path = data['path'];
    final String systemId = data['system_id'];
    final String originDevice = data['origin_device'];
    final String remoteHash = data['hash'];
    final int size = data['size'];
    final int updatedAt = data['updated_at'];

    if (originDevice == await getDeviceNameInternal()) {
      print('ℹ️ SSE: Ignoring event from self ($originDevice)');
      return;
    }

    final paths = await _pathService.getAllSystemPaths();
    if (!paths.containsKey(systemId)) {
      print('ℹ️ SSE: Ignoring event for unconfigured system $systemId');
      return;
    }

    print('🚀 SSE: Remote update detected for $path. Queueing download...');
    
    final destRelPath = _pathResolver.getLocalRelPath(systemId, path.split('/').skip(1).join('/'), {}, _lastScanList);
    final effectivePath = await _pathService.getEffectivePath(systemId);
    final destUri = p.join(effectivePath, destRelPath);

    await _syncStateDb.upsertState(
      destUri, 
      size, 
      updatedAt, 
      remoteHash, 
      'pending_download', 
      systemId: systemId, 
      remotePath: path, 
      relPath: destRelPath
    );
    
    _ref?.read(notificationLogProvider.notifier).addNotification(
      title: 'Remote Update',
      message: 'New save available for ${systemId.toUpperCase()}: ${path.split("/").last}',
      type: NotificationType.info,
      systemId: systemId,
    );
  }
}
