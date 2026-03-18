import 'dart:convert';
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mutex/mutex.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'file_cache.dart';
import '../services/system_path_service.dart';
import '../../../core/services/api_client.dart';
import '../../../core/services/api_client_provider.dart';

final syncRepositoryProvider = Provider<SyncRepository>((ref) {
  final apiClient = ref.watch(apiClientProvider);
  final pathService = ref.watch(systemPathServiceProvider);
  return SyncRepository(apiClient, pathService, FileCache());
});

class SyncRepository {
  final ApiClient _apiClient;
  final SystemPathService _pathService;
  final FileCache _fileCache;
  static const _platform = MethodChannel('com.vaultsync.app/launcher');
  final _syncLock = Mutex();

  String? _cachedDeviceName;
  List<dynamic> _lastScanList = [];

  SyncRepository(this._apiClient, this._pathService, this._fileCache);

  Future<String?> _getMasterKey() async {
     return await _apiClient.getEncryptionKey();
  }

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

  Future<void> _recordSyncSuccess(SharedPreferences prefs, String systemId, String relPath, String hash) async {
    await prefs.setString('journal_${systemId}_$relPath', hash);
  }

  bool _isJournaledSynced(SharedPreferences prefs, String systemId, String relPath, String remoteHash) {
    return prefs.getString('journal_${systemId}_$relPath') == remoteHash;
  }

  String _getCloudRelPath(String systemId, String localRelPath) {
    final sid = systemId.toLowerCase();
    if (sid == 'switch' || sid == 'eden') {
      final parts = localRelPath.split('/');
      // Title IDs are exactly 16 hex chars and ALWAYS start with 0100 on the Switch. 
      // We look for the FIRST segment that matches this pattern to avoid hitting the 0000000000000000 system folder.
      final titleIdx = parts.indexWhere((p) => RegExp(r'^0100[0-9A-Fa-f]{12}$').hasMatch(p));
      
      if (titleIdx != -1) {
          // Flatten: 'some/long/local/path/TitleID/file.dat' -> 'TitleID/file.dat'
          return parts.sublist(titleIdx).join('/');
      }
      return ''; // Not a save file
    } else if (sid == 'ps2' || sid == 'aethersx2' || sid == 'nethersx2' || sid == 'pcsx2' || sid == 'duckstation') {
      if (localRelPath.startsWith('files/memcards/')) return localRelPath.substring(15);
      if (localRelPath.startsWith('files/memcard/')) return localRelPath.substring(14);
      if (localRelPath.startsWith('memcards/')) return localRelPath.substring(9);
      if (localRelPath.startsWith('memcard/')) return localRelPath.substring(8);
      if (localRelPath.startsWith('files/')) return localRelPath.substring(6);
    }
    return localRelPath;
  }

  String _getLocalRelPath(String systemId, String cloudRelPath, Map<String, dynamic> localFiles) {
    if (localFiles.containsKey(cloudRelPath)) return localFiles[cloudRelPath]['originalRelPath'] ?? cloudRelPath;
    
    final sid = systemId.toLowerCase();
    final hasFilesDir = localFiles.values.any((f) => (f['relPath'] as String).startsWith('files/'));

    if (sid == 'ps2' || sid == 'aethersx2' || sid == 'nethersx2' || sid == 'pcsx2' || sid == 'duckstation') {
       if (hasFilesDir) return 'files/memcards/$cloudRelPath';
       return 'memcards/$cloudRelPath';
    }
    if (sid == 'switch' || sid == 'eden') {
       final cloudTitleId = cloudRelPath.split('/').first;
       
       // 1. Try to find where this TitleID ALREADY lives locally
       for (final f in localFiles.values) {
           final localPath = f['originalRelPath'] as String;
           if (localPath.contains(cloudTitleId)) {
               final localParts = localPath.split('/');
               final idx = localParts.indexOf(cloudTitleId);
               final base = localParts.sublist(0, idx).join('/');
               return base.isEmpty ? cloudRelPath : '$base/$cloudRelPath';
           }
       }
       
       // 2. Fallback: Find the FIRST valid 32-char Profile ID on the device (from directory scanner)
       String profileId = '00000000000000000000000000000000';
       final profileRegex = RegExp(r'^[0-9A-Fa-f]{32}$');
       
       // We'll search both files AND directories in the raw scan list
       for (final f in _lastScanList) {
           final path = f['relPath'] as String;
           for (final segment in path.split('/')) {
               if (profileRegex.hasMatch(segment) && segment != '00000000000000000000000000000000') {
                   profileId = segment;
                   break;
               }
           }
           if (profileId != '00000000000000000000000000000000') break;
       }
       
       final prefix = hasFilesDir ? 'files/' : '';
       return '${prefix}nand/user/save/0000000000000000/$profileId/$cloudRelPath';
    }
    return cloudRelPath;
  }
Map<String, Map<String, dynamic>> _processLocalFiles(String systemId, List<dynamic> localList) {
  final Map<String, Map<String, dynamic>> localFiles = {};
  final sid = systemId.toLowerCase();
  final isSwitch = sid == 'switch' || sid == 'eden';

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
      final String cloudRelPath = _getCloudRelPath(systemId, originalRelPath);
      if (cloudRelPath.isEmpty || cloudRelPath.endsWith('/')) continue;
      
      final existing = localFiles[cloudRelPath];
      if (existing == null || (f['lastModified'] as num) > (existing['lastModified'] as num)) {
        f['originalRelPath'] = originalRelPath;
        localFiles[cloudRelPath] = f;
      }
    }
    return localFiles;
  }

  /// Calculates the difference between local and remote files for a given system.
  /// Returns a list of file status maps (Synced, Modified, Local Only, Remote Only).
  Future<List<Map<String, dynamic>>> diffSystem(String systemId, String localPath, {List<String>? ignoredFolders}) async {
    final prefs = await SharedPreferences.getInstance();
    final effectivePath = await _pathService.getEffectivePath(systemId);
    final sid = systemId.toLowerCase();
    final isSwitch = sid == 'eden' || sid == 'switch';
    final response = await _apiClient.get('/api/v1/files', queryParams: {'prefix': isSwitch ? 'switch' : (localPath.toLowerCase().contains('retroarch') ? 'RetroArch' : systemId)});
    final List<dynamic> allRemoteFiles = response['files'] ?? [];
    
    // Switch Pollution Filter: Ignore anything that doesn't start with a Title ID (16 hex chars)
    // or looks like a system path (nand/, config/, etc.)
    final remoteFilesList = isSwitch 
      ? allRemoteFiles.where((f) {
          final path = f['path'] as String;
          final rel = path.startsWith('switch/') ? path.substring(7) : path;
          // Title IDs are 16 hex chars. Check if the first segment looks like one.
          final firstSegment = rel.split('/').first;
          // Standard Switch Title ID: 16 hex chars. 
          // Also ignore common polluted folders like 'nand', 'config', 'files', 'gpu_drivers'
          final isTitleId = RegExp(r'^[0-9A-Fa-f]{16}$').hasMatch(firstSegment);
          final isSystemPath = ['nand', 'config', 'files', 'gpu_drivers'].contains(firstSegment.toLowerCase());
          return isTitleId && !isSystemPath;
        }).toList()
      : allRemoteFiles;

    final bool isRetroArch = localPath.toLowerCase().contains('retroarch');
    final String cloudPrefix = isSwitch ? 'switch' : (isRetroArch ? 'RetroArch' : systemId);
    final remoteFiles = { for (var f in remoteFilesList) f['path']: f };
    
    final String jsonResult = await _platform.invokeMethod('scanRecursive', { 'path': effectivePath, 'systemId': systemId, 'ignoredFolders': ignoredFolders ?? [] });
    final List<dynamic> localList = json.decode(jsonResult);
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
      
      if (localInfo == null) status = 'Remote Only';
      else if (remoteInfo == null) status = 'Local Only';
      else {
        final String remoteHash = remoteInfo['hash'];
        if (_isJournaledSynced(prefs, systemId, relPath, remoteHash)) { status = 'Synced'; }
        else {
          final int localTs = (localInfo['lastModified'] as num).toInt() ~/ 1000;
          final int remoteTs = (remoteInfo['updated_at'] as num).toInt() ~/ 1000;
          if (localInfo['size'] != remoteInfo['size'] || localTs != remoteTs) {
            // PROXY: For display, we assume modified if size/mtime differ. 
            // We only hash during the actual sync turn to avoid UI lag.
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
  /// Uses delta-syncing for large files and convergent encryption.
  Future<void> syncSystem(String systemId, String localPath, {List<String>? ignoredFolders, Function(String)? onProgress, Function(String)? onError, String? filenameFilter, bool fastSync = false}) async {
    await _syncLock.protect(() async {
      final prefs = await SharedPreferences.getInstance();
      final effectivePath = await _pathService.getEffectivePath(systemId);
      final bool isRetroArch = localPath.toLowerCase().contains('retroarch');
      final String cloudPrefix = (systemId.toLowerCase() == 'eden') ? 'switch' : (isRetroArch ? 'RetroArch' : systemId);
      
      try {
        final response = await _apiClient.get('/api/v1/files', queryParams: {'prefix': cloudPrefix});
        final List<dynamic> fileList = response['files'] ?? [];
        final remoteFiles = { for (var f in fileList) f['path']: f };
        
        final String jsonResult = await _platform.invokeMethod('scanRecursive', { 'path': effectivePath, 'systemId': systemId, 'ignoredFolders': ignoredFolders ?? [] });
        final List<dynamic> localList = json.decode(jsonResult);
        _lastScanList = localList;
        final localFiles = _processLocalFiles(systemId, localList);

        final Set<String> cloudRelPaths = { ...localFiles.keys, ...remoteFiles.keys.map((p) => p.substring(cloudPrefix.length + 1)) };

        for (final relPath in cloudRelPaths) {
          if (relPath.isEmpty) continue; // Skip unmappable paths
          final remotePath = '$cloudPrefix/$relPath';
          if (filenameFilter != null && !remotePath.contains(filenameFilter)) continue;
          final localInfo = localFiles[relPath];
          final remoteInfo = remoteFiles[remotePath];

          if (localInfo != null && remoteInfo == null) {
            onProgress?.call('Uploading $relPath...');
            await uploadFile(localInfo['uri'], remotePath, systemId: systemId, relPath: relPath, prefs: prefs);
          } else if (localInfo == null && remoteInfo != null) {
            onProgress?.call('Downloading $relPath...');
            final destRelPath = _getLocalRelPath(systemId, relPath, localFiles);
            await downloadFile(remotePath, effectivePath, destRelPath, systemId: systemId, updatedAt: remoteInfo['updated_at'], serverBlocks: remoteInfo['blocks'], prefs: prefs);
          } else if (localInfo != null && remoteInfo != null) {
            final String remoteHash = remoteInfo['hash'];
            if (_isJournaledSynced(prefs, systemId, relPath, remoteHash)) continue;
            
            final int localTs = (localInfo['lastModified'] as num).toInt();
            final int localSize = (localInfo['size'] as num).toInt();
            
            if (localSize == remoteInfo['size'] && (localTs ~/ 1000) == (remoteInfo['updated_at'] as num).toInt() ~/ 1000) {
              await _recordSyncSuccess(prefs, systemId, relPath, remoteHash);
              continue;
            }

            // Check SQLite Cache before hashing
            String? localHash = await _fileCache.getCachedHash(localInfo['uri'], localSize, localTs);
            if (localHash == null) {
                localHash = await _platform.invokeMethod<String>('calculateHash', {'path': localInfo['uri']});
                if (localHash != null) await _fileCache.updateCache(localInfo['uri'], localSize, localTs, localHash);
            }

            if (localHash == remoteHash) { await _recordSyncSuccess(prefs, systemId, relPath, remoteHash); continue; }
            if (localTs > (remoteInfo['updated_at'] as num)) {
              onProgress?.call('Patching $relPath (Local Newer)...');
              await uploadFile(localInfo['uri'], remotePath, systemId: systemId, relPath: relPath, plainHash: localHash, prefs: prefs);
            } else {
              onProgress?.call('Patching $relPath (Cloud Newer)...');
              await downloadFile(remotePath, effectivePath, localInfo['originalRelPath'], systemId: systemId, updatedAt: remoteInfo['updated_at'], serverBlocks: remoteInfo['blocks'], localUri: localInfo['uri'], prefs: prefs);
            }
          }
        }
      } catch (e) { print('❌ SYNC ERROR: $e'); onError?.call(e.toString()); } 
    });
  }

  /// Encrypts and uploads a file to the server using native hardware acceleration.
  Future<void> uploadFile(dynamic localPathOrFile, String remotePath, {required String systemId, required String relPath, required SharedPreferences prefs, String? plainHash, bool force = false}) async {
    final path = localPathOrFile is File ? localPathOrFile.path : localPathOrFile.toString();
    final Map? info = await _platform.invokeMapMethod('getFileInfo', {'uri': path});
    if (info == null) return;
    final int size = info['size'];
    final int updatedAt = info['lastModified'] ?? 0;
    final String hash = plainHash ?? (await _platform.invokeMethod<String>('calculateHash', {'path': path}) ?? 'unknown');
    final masterKey = await _getMasterKey();
    final baseUrl = await _apiClient.getBaseUrl();
    final token = await _apiClient.getToken();

    List<int>? dirtyIndices;
    if (size > 1024 * 1024) {
      final String blockHashesJson = await _platform.invokeMethod('calculateBlockHashes', {'path': path});
      try {
        final checkResult = await _apiClient.post('/api/v1/blocks/check', body: {'path': remotePath, 'blocks': json.decode(blockHashesJson)});
        final List missing = checkResult['missing'] ?? [];
        if (missing.isEmpty && !force) { await _recordSyncSuccess(prefs, systemId, relPath, hash); return; }
        dirtyIndices = List<int>.from(missing);
      } catch (e) { print('⚠️ Delta check failed: $e'); }
    }

    await _platform.invokeMethod('uploadFileNative', { 'url': '$baseUrl/api/v1/upload', 'token': token, 'masterKey': masterKey, 'remotePath': remotePath, 'uri': path, 'hash': hash, 'deviceName': await _getDeviceName(), 'updatedAt': updatedAt, 'dirtyIndices': dirtyIndices });
    await _recordSyncSuccess(prefs, systemId, relPath, hash);
  }

  /// Downloads and decrypts a file (or specific blocks) from the server.
  Future<void> downloadFile(String remotePath, String localBasePath, String relPath, {required String systemId, required SharedPreferences prefs, String? remoteHash, int? updatedAt, dynamic serverBlocks, String? localUri}) async {
    final baseUrl = await _apiClient.getBaseUrl();
    final token = await _apiClient.getToken();
    final masterKey = await _getMasterKey();
    List<int>? patchIndices;
    if (localUri != null && serverBlocks != null) {
       final String localBlocksJson = await _platform.invokeMethod('calculateBlockHashes', {'path': localUri});
       final List localHashes = json.decode(localBlocksJson);
       final List remoteHashes = serverBlocks is String ? json.decode(serverBlocks) : serverBlocks;
       final dirty = <int>[];
       for (int i = 0; i < remoteHashes.length; i++) { if (i >= localHashes.length || localHashes[i] != remoteHashes[i]) { dirty.add(i); } }
       if (dirty.isNotEmpty && dirty.length < remoteHashes.length) { patchIndices = dirty; }
    }
    final downloadUrl = (patchIndices != null) ? '$baseUrl/api/v1/blocks/download' : '$baseUrl/api/v1/download';
    await _platform.invokeMethod('downloadFileNative', { 'url': downloadUrl, 'token': token, 'masterKey': masterKey, 'remoteFilename': remotePath, 'uri': localBasePath, 'localFilename': relPath, 'updatedAt': updatedAt, 'patchIndices': patchIndices });
    
    if (remoteHash != null) {
      await _recordSyncSuccess(prefs, systemId, relPath, remoteHash);
    }
  }

  /// Deletes a file from the server.
  Future<void> deleteRemoteFile(String path) async { 
    await _apiClient.delete('/api/v1/files', body: {'filename': path}); 
  }

  /// Fetches the version history for a specific remote file.
  Future<List<Map<String, dynamic>>> getFileVersions(String remotePath) async { 
    final response = await _apiClient.get('/api/v1/versions?path=$remotePath'); 
    return List<Map<String, dynamic>>.from(response['versions'] ?? []); 
  }

  /// Restores a specific version of a file from the server.
  Future<void> restoreVersion(String remotePath, String versionId, String localBasePath, String relPath) async {
    final baseUrl = await _apiClient.getBaseUrl();
    final token = await _apiClient.getToken();
    final masterKey = await _getMasterKey();
    await _platform.invokeMethod('downloadFileNative', { 
      'url': '$baseUrl/api/v1/versions/restore', 
      'token': token, 
      'masterKey': masterKey, 
      'remoteFilename': remotePath, 
      'versionId': versionId, 
      'uri': localBasePath, 
      'localFilename': relPath 
    });
  }

  /// Deletes all cloud data associated with a specific system.
  Future<void> deleteSystemCloudData(String systemId) async { 
    await _apiClient.delete('/api/v1/systems/$systemId'); 
  }

  /// Retrieves a list of all active sync conflicts from the server.
  Future<List<Map<String, dynamic>>> getAllRemoteConflicts() async { 
    try { 
      final response = await _apiClient.get('/api/v1/conflicts'); 
      return List<Map<String, dynamic>>.from(response['conflicts'] ?? []); 
    } catch(_) { return []; } 
  }

  /// Scans the local filesystem for files belonging to a specific system.
  Future<Map<String, dynamic>> scanLocalFiles(String path, String systemId) async {
    final String result = await _platform.invokeMethod('scanRecursive', {'path': path, 'systemId': systemId});
    final List list = json.decode(result);
    return { for (var f in list) f['relPath']: f };
  }
}
