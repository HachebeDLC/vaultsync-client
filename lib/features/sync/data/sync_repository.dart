import 'dart:io';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mutex/mutex.dart';
import '../../../core/services/api_client.dart';
import '../../../core/services/api_client_provider.dart';

final syncRepositoryProvider = Provider<SyncRepository>((ref) {
  final apiClient = ref.watch(apiClientProvider);
  return SyncRepository(apiClient);
});

class SyncRepository {
  final ApiClient _apiClient;
  static const _platform = MethodChannel('com.vaultsync.app/launcher');
  final _syncLock = Mutex();

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

  Map<String, dynamic> _processLocalFiles(String systemId, List<dynamic> localList, {Map<String, String>? normalizedToOriginal}) {
    final localFiles = <String, Map<String, dynamic>>{};
    
    if (systemId.toLowerCase() == 'switch') {
      for (var f in localList) {
        final relPath = f['relPath'] as String;
        if (relPath.startsWith('nand/user/save/0000000000000000/')) {
          final parts = relPath.split('/');
          if (parts.length > 5) {
            final userId = parts[4];
            final flattenedPath = parts.sublist(5).join('/');
            
            if (f['isDirectory'] == true) {
              localFiles[flattenedPath] = f;
              continue;
            }

            final existing = localFiles[flattenedPath];
            if (existing == null || existing['isDirectory'] == true || (f['lastModified'] as num) > (existing['lastModified'] as num)) {
              localFiles[flattenedPath] = f;
              normalizedToOriginal?[flattenedPath] = userId;
            }
          }
        }
      }
    } else {
      for (var f in localList) {
        localFiles[f['relPath']] = f;
      }
    }
    return localFiles;
  }

  String? _detectPrimarySwitchUser(List<dynamic> localList) {
    final Map<String, Set<String>> profileGameCounts = {};
    for (var f in localList) {
      final relPath = f['relPath'] as String;
      if (relPath.startsWith('nand/user/save/0000000000000000/')) {
        final parts = relPath.split('/');
        if (parts.length > 5) {
          final userId = parts[4];
          final titleId = parts[5];
          profileGameCounts.putIfAbsent(userId, () => {}).add(titleId);
        }
      }
    }
    if (profileGameCounts.isEmpty) return null;
    return profileGameCounts.entries
        .reduce((a, b) => a.value.length > b.value.length ? a : b)
        .key;
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
    
    final localFiles = _processLocalFiles(systemId, localList);
    final detectedUserId = systemId.toLowerCase() == 'switch' ? _detectPrimarySwitchUser(localList) : null;

    final List<Map<String, dynamic>> results = [];

    final Set<String> initialRelPaths = {
      ...localFiles.keys,
      ...remoteFiles.keys.map((p) {
        final rawRel = p.substring(cloudPrefix.length + 1);
        // Map remote files to the primary local user for the UI
        if (systemId.toLowerCase() == 'switch' && detectedUserId != null) {
          return '$detectedUserId/$rawRel';
        }
        return rawRel;
      })
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
      String remotePath = '$cloudPrefix/$relPath';
      
      // If it's switch, the cloud path strips the User ID prefix (ANY 32-char hex ID)
      if (systemId.toLowerCase() == 'switch') {
        final parts = relPath.split('/');
        if (parts.isNotEmpty && parts[0].length == 32) {
          remotePath = '$cloudPrefix/${parts.sublist(1).join('/')}';
        }
      }

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

  Future<void> syncSystem(String systemId, String localPath, {List<String>? ignoredFolders, Function(String)? onProgress, Function(String)? onError, String? filenameFilter, bool fastSync = false}) async {
    await _syncLock.protect(() async {
      print('🔄 SYNC: Starting system $systemId at $localPath (Fast: $fastSync)');
      
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
        
        final localFiles = _processLocalFiles(systemId, localList);

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
            final hash = fastSync ? 'pending' : await _platform.invokeMethod<String>('calculateHash', {'path': localInfo['uri']});
            toUpload.add({'local': localInfo['uri'], 'remote': remotePath, 'rel': localRelPath, 'hash': hash});
          } else {
            final remoteInfo = remoteFiles[remotePath]!;
            final int remoteTs = (remoteInfo['updated_at'] as num).toInt() ~/ 1000;
            final int remoteSize = (remoteInfo['size'] as num?)?.toInt() ?? -1;

            // OPTIMIZATION: If size and timestamp match exactly, skip
            if (localSize == remoteSize && localTs == remoteTs) {
              continue; 
            }

            if (fastSync) {
              // In Fast mode, we only upload if local is NEWER. 
              // We skip the expensive hash check and skip downloads.
              if (localTs > remoteTs) {
                toUpload.add({'local': localInfo['uri'], 'remote': remotePath, 'rel': localRelPath, 'hash': null});
              }
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
              } catch (e) {
                print('⚠️ SYNC: Could not align timestamp for $localRelPath: $e');
              }
            }
          }
        }
        
        // Downloads only in full sync mode
        if (!fastSync) {
          for (final remotePath in remoteFiles.keys) {
            final relPath = remotePath.substring(systemId.length + 1);
            if (filenameFilter != null && !remotePath.contains(filenameFilter)) continue;
            
            // Switch hardening: Ignore old structure files from the server
            if (systemId.toLowerCase() == 'switch' && relPath.startsWith('nand/')) continue;
            
            if (!localFiles.containsKey(relPath)) {
              toDownload.add({'remote': remotePath, 'rel': relPath});
            }
          }
        }

        print('📊 SYNC: Calculated diffs. Uploading ${toUpload.length} files. Downloading ${toDownload.length} files.');
        int count = 0;
        final total = toUpload.length + toDownload.length;

        for (final item in toUpload) {
          count++;
          onProgress?.call('Uploading ${item['rel']} ($count/$total)');
          try {
            await uploadFile(item['local'], item['remote'], plainHash: item['hash']);
          } catch (e) {
            print('❌ SYNC: Upload failed for ${item['rel']}: $e');
            onError?.call('Upload failed for ${item['rel']}: $e');
          }
        }
        for (final item in toDownload) {
          count++;
          onProgress?.call('Downloading ${item['rel']} ($count/$total)');
          final remoteInfo = remoteFiles[item['remote']]!;
          
          final detectedUserId = systemId.toLowerCase() == 'switch' ? _detectPrimarySwitchUser(localList) : null;
          String localRelPath = item['rel'];
          if (systemId.toLowerCase() == 'switch' && detectedUserId != null) {
            // Cloud path: <TITLE_ID>/file -> Local path: nand/user/save/0000000000000000/ACTUAL_HEX/<TITLE_ID>/file
            localRelPath = 'nand/user/save/0000000000000000/$detectedUserId/$localRelPath';
          }
          
          try {
            await downloadFile(item['remote'], localPath, localRelPath, updatedAt: remoteInfo['updated_at']);
          } catch (e) {
            print('❌ SYNC: Download failed for ${item['rel']}: $e');
            onError?.call('Download failed for ${item['rel']}: $e');
            onProgress?.call('Warning: Failed to download ${item['rel']}');
          }
        }
      } catch (e) { 
        print('❌ SYNC ERROR: $e'); 
        onError?.call('Sync process failed: $e');
      } 
    });
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

    // The server now expects a POST for version restoration for better security
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
