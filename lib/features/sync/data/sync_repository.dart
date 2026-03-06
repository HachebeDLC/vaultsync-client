import 'dart:io';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/services/api_client.dart';
import '../../../core/services/api_client_provider.dart';

final syncRepositoryProvider = Provider<SyncRepository>((ref) {
  final apiClient = ref.watch(apiClientProvider);
  return SyncRepository(apiClient);
});

class SyncRepository {
  final ApiClient _apiClient;
  static const _platform = MethodChannel('com.vaultsync.app/launcher');
  bool _isSyncingGlobal = false;

  SyncRepository(this._apiClient);

  Future<String?> _getMasterKey() async {
    return await _apiClient.getEncryptionKey();
  }

  Future<String> _getDeviceName() async {
    final deviceInfo = DeviceInfoPlugin();
    if (Platform.isAndroid) {
      final androidInfo = await deviceInfo.androidInfo;
      return androidInfo.model;
    }
    return 'Web/PC';
  }

  Future<List<Map<String, dynamic>>> diffSystem(String systemId, String localPath, {List<String>? ignoredFolders}) async {
    final response = await _apiClient.get('/api/v1/files');
    final List<dynamic> fileList = response['files'] ?? [];
    
    // Determine the correct cloud prefix. 
    final bool isRetroArch = localPath.toLowerCase().contains('retroarch');
    final String cloudPrefix = isRetroArch ? 'RetroArch' : systemId;
    
    final remoteFiles = { for (var f in fileList) if ((f['path'] as String).startsWith('$cloudPrefix/')) f['path']: f };
    
    final String jsonResult = await _platform.invokeMethod('scanRecursive', {
      'path': localPath, 
      'systemId': systemId,
      'ignoredFolders': ignoredFolders ?? [],
    });
    final List<dynamic> localList = json.decode(jsonResult);
    
    final localFiles = { for (var f in localList) f['relPath']: f };

    final List<Map<String, dynamic>> results = [];
    final Set<String> initialRelPaths = {
      ...localFiles.keys,
      ...remoteFiles.keys.map((p) => p.substring(cloudPrefix.length + 1))
    };

    // Ensure all parent directories exist in the list to support the accordion UI
    final Set<String> allRelPaths = {};
    for (final path in initialRelPaths) {
      if (path.isEmpty) continue;
      allRelPaths.add(path);
      final parts = path.split('/');
      for (int i = 1; i < parts.length; i++) {
        allRelPaths.add(parts.sublist(0, i).join('/'));
      }
    }

    for (final relPath in allRelPaths) {
      final remotePath = '$cloudPrefix/$relPath';
      final localInfo = localFiles[relPath];
      final remoteInfo = remoteFiles[remotePath];

      // Robust directory determination
      bool isDirectory = false;
      if (localInfo != null && localInfo['isDirectory'] == true) {
        isDirectory = true;
      } else if (remoteInfo == null && !remoteFiles.containsKey(remotePath)) {
        isDirectory = true;
      }

      String status = 'Synced';
      String type = isDirectory ? 'Folder' : 'Save';
      
      if (!isDirectory) {
        final lowerPath = relPath.toLowerCase();
        if (lowerPath.contains('.state') || lowerPath.endsWith('.png')) {
          type = 'State';
        }

        if (localInfo == null) {
          status = 'Remote Only';
        } else if (remoteInfo == null) {
          status = 'Local Only';
        } else {
          final int localTs = (localInfo['lastModified'] as num).toInt() ~/ 1000;
          final int remoteTs = (remoteInfo['updated_at'] as num).toInt() ~/ 1000;
          final int localSize = (localInfo['size'] as num).toInt();
          final int remoteSize = (remoteInfo['size'] as num?)?.toInt() ?? -1;

          if (localSize != remoteSize || localTs != remoteTs) {
          // Heuristic failed, let's check the hash for the ultimate truth
          print('⚖️ DIFF: Heuristic mismatch for $relPath. Local: Ts=$localTs, Sz=$localSize | Remote: Ts=$remoteTs, Sz=$remoteSize');
          
          final localHash = await _platform.invokeMethod<String>('calculateHash', {'path': localInfo['uri']});
          if (localHash != remoteInfo['hash']) {
            status = 'Modified';
            print('🚩 DIFF: True modification confirmed by hash mismatch for $relPath');
          } else {
            // Hash matches! Content is same. Let's fix the local timestamp to align with server.
            status = 'Synced';
            print('✅ DIFF: Hash match for $relPath. Aligning local timestamp...');
            try {
              await _platform.invokeMethod('setFileTimestamp', {
                'path': localInfo['uri'],
                'updatedAt': remoteInfo['updated_at']
              });
            } catch (e) {
              print('⚠️ DIFF: Could not update timestamp: $e');
            }
          }
        }
        }
      } else {
        status = 'Folder';
      }

      results.add({
        'relPath': relPath,
        'remotePath': remotePath,
        'status': status,
        'type': type,
        'localInfo': localInfo,
        'remoteInfo': remoteInfo,
        'isDirectory': isDirectory,
        'name': localInfo?['name'] ?? relPath.split('/').last,
      });
    }

    results.sort((a, b) => (a['relPath'] as String).compareTo(b['relPath'] as String));
    return results;
  }

  Future<void> syncSystem(String systemId, String localPath, {List<String>? ignoredFolders, Function(String)? onProgress, String? filenameFilter}) async {
    if (_isSyncingGlobal) return;
    _isSyncingGlobal = true;
    print('🔄 SYNC: Starting system $systemId at $localPath');
    
    try {
      final response = await _apiClient.get('/api/v1/files');
      final List<dynamic> fileList = response['files'] ?? [];
      final remoteFiles = { for (var f in fileList) if ((f['path'] as String).startsWith('$systemId/')) f['path']: f };
      
      final String jsonResult = await _platform.invokeMethod('scanRecursive', {
        'path': localPath, 
        'systemId': systemId,
        'ignoredFolders': ignoredFolders ?? [],
      });
      final List<dynamic> localList = json.decode(jsonResult);
      final localFiles = { for (var f in localList) f['relPath']: f };

      List<Map<String, dynamic>> toUpload = [];
      List<Map<String, dynamic>> toDownload = [];

      for (final localRelPath in localFiles.keys) {
        final localInfo = localFiles[localRelPath]!;
        if (localInfo['isDirectory'] == true) continue;

        final remotePath = '$systemId/$localRelPath';
        if (filenameFilter != null && !remotePath.contains(filenameFilter)) continue;

        final int localTs = (localInfo['lastModified'] as num).toInt() ~/ 1000;
        final int localSize = (localInfo['size'] as num).toInt();

        if (!remoteFiles.containsKey(remotePath)) {
          print('➕ SYNC: New local file found: $localRelPath');
          final hash = await _platform.invokeMethod<String>('calculateHash', {'path': localInfo['uri']});
          toUpload.add({'local': localInfo['uri'], 'remote': remotePath, 'rel': localRelPath, 'hash': hash});
        } else {
          final remoteInfo = remoteFiles[remotePath]!;
          final int remoteTs = (remoteInfo['updated_at'] as num).toInt() ~/ 1000;
          final int remoteSize = (remoteInfo['size'] as num?)?.toInt() ?? -1;

          // OPTIMIZATION: If size and timestamp match exactly, skip hashing
          if (localSize == remoteSize && localTs == remoteTs) {
            continue; 
          }

          final localHash = await _platform.invokeMethod<String>('calculateHash', {'path': localInfo['uri']});

          if (localHash != remoteInfo['hash']) {
            if (localTs > remoteTs) {
              toUpload.add({'local': localInfo['uri'], 'remote': remotePath, 'rel': localRelPath, 'hash': localHash});
            } else {
              toDownload.add({'remote': remotePath, 'rel': localRelPath});
            }
          } else {
            // Hash matches but timestamp doesn't! 'Touch' local to match server
            try {
              await _platform.invokeMethod('setFileTimestamp', {
                'path': localInfo['uri'],
                'updatedAt': remoteInfo['updated_at']
              });
            } catch (_) {}
          }
        }
      }
      for (final remotePath in remoteFiles.keys) {
        final relPath = remotePath.substring(systemId.length + 1);
        if (filenameFilter != null && !remotePath.contains(filenameFilter)) continue;
        if (!localFiles.containsKey(relPath)) {
          toDownload.add({'remote': remotePath, 'rel': relPath});
        }
      }

      print('📊 SYNC: Calculated diffs. Uploading ${toUpload.length} files. Downloading ${toDownload.length} files.');
      int count = 0;
      final total = toUpload.length + toDownload.length;

      for (final item in toUpload) {
        count++;
        onProgress?.call('Uploading ${item['rel']} ($count/$total)');
        await uploadFile(item['local'], item['remote'], plainHash: item['hash']);
      }
      for (final item in toDownload) {
        count++;
        onProgress?.call('Downloading ${item['rel']} ($count/$total)');
        final remoteInfo = remoteFiles[item['remote']]!;
        await downloadFile(item['remote'], localPath, item['rel'], updatedAt: remoteInfo['updated_at']);
      }
    } catch (e) { print('❌ SYNC ERROR: $e'); } 
    finally { _isSyncingGlobal = false; }
  }

  Future<void> uploadFile(dynamic localPathOrFile, String remotePath, {String? plainHash, bool force = false}) async {
    final path = localPathOrFile is File ? localPathOrFile.path : localPathOrFile.toString();
    
    final Map<String, dynamic>? info = await _platform.invokeMapMethod('getFileInfo', {'uri': path});
    if (info == null) return;
    final int size = info['size'];
    final int updatedAt = info['lastModified'] ?? 0;
    final String hash = plainHash ?? (await _platform.invokeMethod<String>('calculateHash', {'path': path}) ?? 'unknown');
    final deviceName = await _getDeviceName();
    final masterKey = await _getMasterKey();

    final baseUrl = await _apiClient.getBaseUrl();
    final token = await _apiClient.getToken();

    List<int>? dirtyIndices;

    if (size > 1024 * 1024) {
      final String blockHashesJson = await _platform.invokeMethod('calculateBlockHashes', {'path': path});
      final List<dynamic> blockHashes = json.decode(blockHashesJson);
      
      try {
        final checkResult = await _apiClient.post('/api/v1/blocks/check', body: {'path': remotePath, 'blocks': blockHashes});
        final List<dynamic> missing = checkResult['missing'] ?? [];
        if (missing.isEmpty) return;
        dirtyIndices = List<int>.from(missing);
      } catch (e) { print('⚠️ Delta check failed: $e'); }
    }

    await _platform.invokeMethod('uploadFileNative', {
      'url': '$baseUrl/api/v1/upload',
      'token': token,
      'masterKey': masterKey,
      'remotePath': remotePath,
      'uri': path,
      'hash': hash,
      'deviceName': deviceName,
      'updatedAt': updatedAt,
      'dirtyIndices': dirtyIndices,
    });
  }

  Future<void> downloadFile(String remotePath, String localBasePath, String relPath, {int? updatedAt}) async {
    final baseUrl = await _apiClient.getBaseUrl();
    final token = await _apiClient.getToken();
    final masterKey = await _getMasterKey();

    await _platform.invokeMethod('downloadFileNative', {
      'url': '$baseUrl/api/v1/download',
      'token': token,
      'masterKey': masterKey,
      'remoteFilename': remotePath,
      'uri': localBasePath,
      'localFilename': relPath,
      'updatedAt': updatedAt,
    });
  }

  Future<void> deleteRemoteFile(String path) async {
    await _apiClient.delete('/api/v1/files', body: {'filename': path});
  }

  Future<List<Map<String, dynamic>>> getFileVersions(String remotePath) async {
    final response = await _apiClient.get('/api/v1/versions?path=$remotePath');
    return List<Map<String, dynamic>>.from(response['versions'] ?? []);
  }

  Future<void> restoreVersion(String remotePath, int version, String localBasePath, String relPath) async {
    final baseUrl = await _apiClient.getBaseUrl();
    final token = await _apiClient.getToken();
    final masterKey = await _getMasterKey();

    await _platform.invokeMethod('downloadFileNative', {
      'url': '$baseUrl/api/v1/versions/restore',
      'token': token,
      'masterKey': masterKey,
      'remoteFilename': remotePath,
      'version': version,
      'uri': localBasePath,
      'localFilename': relPath,
    });
  }

  Future<void> deleteSystemCloudData(String systemId) async { 
    await _apiClient.delete('/api/v1/systems/$systemId');
  }

  Future<List<Map<String, dynamic>>> getAllRemoteConflicts() async { 
    final response = await _apiClient.get('/api/v1/conflicts');
    return List<Map<String, dynamic>>.from(response['conflicts'] ?? []);
  }

  Future<Map<String, dynamic>> scanLocalFiles(String path, String systemId) async {
    final String result = await _platform.invokeMethod('scanRecursive', {'path': path, 'systemId': systemId});
    final List<dynamic> list = json.decode(result);
    return { for (var f in list) f['relPath']: f };
  }
}
