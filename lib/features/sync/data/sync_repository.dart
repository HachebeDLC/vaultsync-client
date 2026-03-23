import 'dart:convert';
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mutex/mutex.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'file_cache.dart';
import 'dart_file_scanner.dart';
import 'dart_native_crypto.dart';
import '../services/sync_network_service.dart';
import '../services/sync_path_resolver.dart';
import '../services/system_path_service.dart';
import '../../../core/services/api_client.dart';
import '../../../core/services/api_client_provider.dart';

final syncPathResolverProvider = Provider<SyncPathResolver>((ref) => SyncPathResolver());

final syncNetworkServiceProvider = Provider<SyncNetworkService>((ref) {
  final apiClient = ref.watch(apiClientProvider);
  return SyncNetworkService(apiClient);
});

final syncRepositoryProvider = Provider<SyncRepository>((ref) {
  final apiClient = ref.watch(apiClientProvider);
  final pathService = ref.watch(systemPathServiceProvider);
  final networkService = ref.watch(syncNetworkServiceProvider);
  final pathResolver = ref.watch(syncPathResolverProvider);
  return SyncRepository(apiClient, pathService, FileCache(), networkService, pathResolver);
});

/// Repository responsible for orchestrating the synchronization of emulator save data
/// between the local filesystem and the VaultSync server.
class SyncRepository {
  final ApiClient _apiClient;
  final SystemPathService _pathService;
  final FileCache _fileCache;
  final SyncNetworkService _networkService;
  final SyncPathResolver _pathResolver;
  static const _platform = MethodChannel('com.vaultsync.app/launcher');
  final _syncLock = Mutex();

  String? _cachedDeviceName;
  List<dynamic> _lastScanList = [];

  SyncRepository(this._apiClient, this._pathService, this._fileCache, this._networkService, this._pathResolver);

  Future<String> _getDeviceName() async {
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
    return prefs.getString(key) == remoteHash;
  }

  Map<String, Map<String, dynamic>> _processLocalFiles(String systemId, List<dynamic> localList) {
    final Map<String, Map<String, dynamic>> localFiles = {};

    // Check if this is a package root (contains 'files/' folder)
    final bool isPkgRoot = localList.any((f) => f['relPath'] == 'files' || f['relPath'].startsWith('files/'));

    for (var f in localList) {
      if (f['isDirectory'] == true) continue;
      final String originalRelPath = f['relPath'];

      // FILTER: If we are at package root, ignore any save files that aren't in the correct subfolders
      if (isPkgRoot && !originalRelPath.contains('/')) {
           final ext = originalRelPath.split('.').last.toLowerCase();
           if (['ps2', 'srm', 'sav', 'save', 'state'].contains(ext)) continue;
      }
      final String cloudRelPath = _pathResolver.getCloudRelPath(systemId, originalRelPath);
      if (cloudRelPath.isEmpty || cloudRelPath.endsWith('/')) continue;
      
      final existing = localFiles[cloudRelPath];
      if (existing == null || (f['lastModified'] as num) > (existing['lastModified'] as num)) {
        f['originalRelPath'] = originalRelPath;
        localFiles[cloudRelPath] = f;
      }
    }
    return localFiles;
  }

  final Map<String, (List<dynamic>, DateTime)> _scanCache = {};
  static const _scanCacheTTL = Duration(seconds: 30);

  Future<List<dynamic>> _getCachedOrNewScan(String systemId, String effectivePath, List<String>? ignoredFolders) async {
    final cached = _scanCache[systemId];
    if (cached != null && DateTime.now().difference(cached.$2) < _scanCacheTTL) {
       _lastScanList = cached.$1;
       return _lastScanList;
    }
    
    List<dynamic> result;
    if (Platform.isLinux || Platform.isWindows || Platform.isMacOS) {
      result = await DartFileScanner.scanRecursive(effectivePath, systemId, ignoredFolders ?? []);
    } else {
      final String jsonResult = await _platform.invokeMethod('scanRecursive', { 'path': effectivePath, 'systemId': systemId, 'ignoredFolders': ignoredFolders ?? [] });
      result = json.decode(jsonResult);
    }
    
    _lastScanList = result;
    _scanCache[systemId] = (result, DateTime.now());
    return result;
  }

  /// Calculates the difference between local and remote files for a given system.
  Future<List<Map<String, dynamic>>> diffSystem(String systemId, String localPath, {List<String>? ignoredFolders}) async {
    final prefs = await SharedPreferences.getInstance();
    final effectivePath = await _pathService.getEffectivePath(systemId);
    final sid = systemId.toLowerCase();
    final isSwitch = sid == 'eden' || sid == 'switch';
    final response = await _apiClient.get('/api/v1/files', queryParams: {'prefix': isSwitch ? 'switch' : (localPath.toLowerCase().contains('retroarch') ? 'RetroArch' : systemId)});
    final List<dynamic> allRemoteFiles = response['files'] ?? [];
    
    // Remote Cloud Pollution Filter
    final remoteFilesList = allRemoteFiles.where((f) {
      final path = f['path'] as String;
      final rel = path.contains('/') ? path.split('/').skip(1).join('/') : path;
      final firstSegment = rel.split('/').first.toLowerCase();

      if (isSwitch) {
         final isTitleId = RegExp(r'^[0-9A-Fa-f]{16}$').hasMatch(firstSegment);
         final isSystemPath = ['nand', 'config', 'files', 'gpu_drivers'].contains(firstSegment);
         return isTitleId && !isSystemPath;
      }
      
      if (sid == '3ds' || sid == 'azahar') {
         return rel.startsWith('saves/');
      }

      return true;
    }).toList();

    final bool isRetroArch = localPath.toLowerCase().contains('retroarch');
    final String cloudPrefix = isSwitch ? 'switch' : (isRetroArch ? 'RetroArch' : systemId);
    final remoteFiles = { for (var f in remoteFilesList) f['path']: f };
    
    final List<dynamic> localList = await _getCachedOrNewScan(systemId, effectivePath, ignoredFolders);
    final localFiles = _processLocalFiles(systemId, localList);

    final Set<String> cloudRelPaths = { ...localFiles.keys, ...remoteFiles.keys.map((p) => p.substring(cloudPrefix.length + 1)) };
    final List<Map<String, dynamic>> results = [];

    for (final relPath in cloudRelPaths) {
      if (relPath.isEmpty) continue;
      String remotePath = '$cloudPrefix/$relPath';
      final localInfo = localFiles[relPath];
      final remoteInfo = remoteFiles[remotePath];
      
      String status = 'Synced';
      String type = (relPath.toLowerCase().contains('.state') || relPath.toLowerCase().endsWith('.png')) ? 'State' : 'Save';
      
      if (localInfo == null) {
        status = 'Remote Only';
      } else if (remoteInfo == null) status = 'Local Only';
      else {
        final String remoteHash = remoteInfo['hash'];
        if (_isJournaledSynced(prefs, systemId, relPath, remoteHash)) { status = 'Synced'; }
        else {
          final int localTs = (localInfo['lastModified'] as num).toInt() ~/ 1000;
          final int remoteTs = (remoteInfo['updated_at'] as num).toInt() ~/ 1000;
          if (localInfo['size'] != remoteInfo['size'] || localTs != remoteTs) {
            status = 'Modified';
          }
        }
      }

      results.add({ 'relPath': relPath, 'remotePath': remotePath, 'status': status, 'type': type, 'localInfo': localInfo, 'remoteInfo': remoteInfo, 'isDirectory': false, 'name': relPath.split('/').last });
    }
    results.sort((a, b) => (a['relPath'] as String).compareTo(b['relPath'] as String));
    return results;
  }

  /// Synchronizes a system's save files between the local device and the server.
  Future<void> syncSystem(String systemId, String localPath, {List<String>? ignoredFolders, Function(String)? onProgress, Function(String)? onError, String? filenameFilter, bool fastSync = false, bool Function()? isCancelled}) async {
    await _syncLock.protect(() async {
      final prefs = await SharedPreferences.getInstance();
      final effectivePath = await _pathService.getEffectivePath(systemId);
      final bool isRetroArch = localPath.toLowerCase().contains('retroarch');
      final String cloudPrefix = (systemId.toLowerCase() == 'eden') ? 'switch' : (isRetroArch ? 'RetroArch' : systemId);
      
      try {
        final response = await _apiClient.get('/api/v1/files', queryParams: {'prefix': cloudPrefix});
        final List<dynamic> fileList = response['files'] ?? [];
        final remoteFiles = { for (var f in fileList) f['path']: f };
        
        final List<dynamic> localList = await _getCachedOrNewScan(systemId, effectivePath, ignoredFolders);
        final localFiles = _processLocalFiles(systemId, localList);

        final Set<String> cloudRelPaths = { ...localFiles.keys, ...remoteFiles.keys.map((p) => p.substring(cloudPrefix.length + 1)) };
        final List<Map<String, dynamic>> pendingCacheUpdates = [];

        for (final relPath in cloudRelPaths) {
          if (isCancelled?.call() == true) {
            onProgress?.call('Sync Cancelled');
            break;
          }
          if (relPath.isEmpty) continue;
          final remotePath = '$cloudPrefix/$relPath';
          if (filenameFilter != null && !remotePath.contains(filenameFilter)) continue;
          final localInfo = localFiles[relPath];
          final remoteInfo = remoteFiles[remotePath];

          if (localInfo != null && remoteInfo == null) {
            onProgress?.call('Uploading $relPath...');
            await uploadFile(localInfo['uri'], remotePath, systemId: systemId, relPath: relPath, prefs: prefs);
          } else if (localInfo == null && remoteInfo != null) {
            onProgress?.call('Downloading $relPath...');
            final destRelPath = _pathResolver.getLocalRelPath(systemId, relPath, localFiles, _lastScanList);
            await downloadFile(remotePath, effectivePath, destRelPath, systemId: systemId, updatedAt: remoteInfo['updated_at'], serverBlocks: remoteInfo['blocks'], prefs: prefs, fileSize: (remoteInfo['size'] as num).toInt());
          } else if (localInfo != null && remoteInfo != null) {
            final String remoteHash = remoteInfo['hash'];
            if (_isJournaledSynced(prefs, systemId, relPath, remoteHash)) continue;
            
            final int localTs = (localInfo['lastModified'] as num).toInt();
            final int localSize = (localInfo['size'] as num).toInt();
            
            if (localSize == remoteInfo['size'] && (localTs ~/ 1000) == (remoteInfo['updated_at'] as num).toInt() ~/ 1000) {
              _recordSyncSuccess(prefs, systemId, relPath, remoteHash);
              continue;
            }

            String? localHash = await _fileCache.getCachedHash(localInfo['uri'], localSize, localTs);
            if (localHash == null) {
                localHash = (Platform.isLinux || Platform.isWindows || Platform.isMacOS)
                    ? await DartNativeCrypto.calculateHash(localInfo['uri'])
                    : await _platform.invokeMethod<String>('calculateHash', {'path': localInfo['uri']});
                
                if (localHash != null) {
                  pendingCacheUpdates.add({
                    'path': localInfo['uri'],
                    'size': localSize,
                    'lastModified': localTs,
                    'hash': localHash,
                  });
                }
            }

            if (localHash == remoteHash) { _recordSyncSuccess(prefs, systemId, relPath, remoteHash); continue; }
            if (localTs > (remoteInfo['updated_at'] as num)) {
              onProgress?.call('Patching $relPath (Local Newer)...');
              await uploadFile(localInfo['uri'], remotePath, systemId: systemId, relPath: relPath, plainHash: localHash, prefs: prefs);
            } else {
              onProgress?.call('Patching $relPath (Cloud Newer)...');
              await downloadFile(remotePath, effectivePath, localInfo['originalRelPath'], systemId: systemId, updatedAt: remoteInfo['updated_at'], serverBlocks: remoteInfo['blocks'], localUri: localInfo['uri'], prefs: prefs, fileSize: (remoteInfo['size'] as num).toInt());
            }
          }
        }
        
        if (pendingCacheUpdates.isNotEmpty) {
           await _fileCache.updateCacheBatch(pendingCacheUpdates);
        }
        
        await _commitSyncJournal(prefs);
      } catch (e) { 
        print('❌ SYNC ERROR: $e'); 
        onError?.call(e.toString()); 
        rethrow;
      } 
    });
  }

  Future<void> uploadFile(dynamic localPathOrFile, String remotePath, {required String systemId, required String relPath, required SharedPreferences prefs, String? plainHash, bool force = false}) async {
    final path = localPathOrFile is File ? localPathOrFile.path : localPathOrFile.toString();
    await _networkService.uploadFile(
      path, 
      remotePath, 
      systemId: systemId, 
      relPath: relPath, 
      deviceName: await _getDeviceName(),
      onRecordSuccess: (sid, rp, h) => _recordSyncSuccess(prefs, sid, rp, h),
      plainHash: plainHash, 
      force: force
    );
  }

  Future<void> downloadFile(String remotePath, String localBasePath, String relPath, {required String systemId, required SharedPreferences prefs, required int fileSize, String? remoteHash, int? updatedAt, dynamic serverBlocks, String? localUri}) async {
    await _networkService.downloadFile(
      remotePath, 
      localBasePath, 
      relPath, 
      systemId: systemId, 
      fileSize: fileSize, 
      onRecordSuccess: (sid, rp, h) => _recordSyncSuccess(prefs, sid, rp, h),
      remoteHash: remoteHash, 
      updatedAt: updatedAt, 
      serverBlocks: serverBlocks, 
      localUri: localUri
    );
  }

  /// Deletes a specific file from the server storage.
  Future<void> deleteRemoteFile(String path) async { 
    await _apiClient.delete('/api/v1/files', body: {'filename': path}); 
  }

  /// Retrieves the historical version list for a given remote file.
  Future<List<Map<String, dynamic>>> getFileVersions(String remotePath) async { 
    final response = await _apiClient.get('/api/v1/versions?path=$remotePath'); 
    return List<Map<String, dynamic>>.from(response['versions'] ?? []); 
  }

  Future<void> restoreVersion(String remotePath, String versionId, String localBasePath, String relPath, int fileSize) async {
    await _networkService.restoreVersion(remotePath, versionId, localBasePath, relPath, fileSize);
  }

  /// Wipes all cloud data associated with a specific system (e.g. 'ps2').
  Future<void> deleteSystemCloudData(String systemId) async { 
    await _apiClient.delete('/api/v1/systems/$systemId'); 
  }

  /// Fetches all active sync conflicts (files present in multiple devices with differing hashes).
  Future<List<Map<String, dynamic>>> getAllRemoteConflicts() async { 
    try { 
      final response = await _apiClient.get('/api/v1/conflicts'); 
      return List<Map<String, dynamic>>.from(response['conflicts'] ?? []); 
    } catch(_) { return []; } 
  }

  /// Performs a shallow scan of the local filesystem for a specific system's saves.
  Future<Map<String, dynamic>> scanLocalFiles(String path, String systemId) async {
    List<dynamic> list;
    if (Platform.isLinux || Platform.isWindows || Platform.isMacOS) {
      list = await DartFileScanner.scanRecursive(path, systemId, []);
    } else {
      final String result = await _platform.invokeMethod('scanRecursive', {'path': path, 'systemId': systemId});
      list = json.decode(result);
    }
    return { for (var f in list) f['relPath']: f };
  }
}
