import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import '../../../core/services/api_client.dart';
import '../data/dart_native_crypto.dart';

class SyncNetworkService {
  final ApiClient _apiClient;
  static const _platform = MethodChannel('com.vaultsync.app/launcher');

  SyncNetworkService(this._apiClient);

  Future<void> uploadFile(
    String path, 
    String remotePath, {
    required String systemId, 
    required String relPath, 
    required String deviceName,
    required Function(String, String, String) onRecordSuccess,
    String? plainHash, 
    bool force = false,
  }) async {
    final Map? info = (Platform.isLinux || Platform.isWindows || Platform.isMacOS) 
        ? await DartNativeCrypto.getFileInfo(path)
        : await _platform.invokeMapMethod('getFileInfo', {'uri': path});

    if (info == null) return;
    final int size = info['size'];
    final int updatedAt = info['lastModified'] ?? 0;

    final String hash = plainHash ?? (
      (Platform.isLinux || Platform.isWindows || Platform.isMacOS)
        ? await DartNativeCrypto.calculateHash(path)
        : (await _platform.invokeMethod<String>('calculateHash', {'path': path}) ?? 'unknown')
    );

    final masterKey = await _apiClient.getEncryptionKey();
    final baseUrl = await _apiClient.getBaseUrl();
    final token = await _apiClient.getToken();

    List<int>? dirtyIndices;
    if (size > 1024 * 1024) {
      final String blockHashesJson = (Platform.isLinux || Platform.isWindows || Platform.isMacOS)
          ? await DartNativeCrypto.calculateBlockHashes(path, masterKey: masterKey)
          : await _platform.invokeMethod('calculateBlockHashes', {'path': path, 'masterKey': masterKey});

      try {
        final checkResult = await _apiClient.post('/api/v1/blocks/check', body: {'path': remotePath, 'blocks': json.decode(blockHashesJson)});
        final List missing = checkResult['missing'] ?? [];
        if (missing.isEmpty && !force) { 
          onRecordSuccess(systemId, relPath, hash); 
          return; 
        }
        dirtyIndices = List<int>.from(missing);
      } catch (e) { print('⚠️ Delta check failed: $e'); }
    }

    final uploadArgs = { 
      'url': '$baseUrl/api/v1/upload', 
      'token': token, 
      'masterKey': masterKey, 
      'remotePath': remotePath, 
      'uri': path, 
      'hash': hash, 
      'deviceName': deviceName, 
      'updatedAt': updatedAt, 
      'dirtyIndices': dirtyIndices 
    };

    if (Platform.isLinux || Platform.isWindows || Platform.isMacOS) {
      await DartNativeCrypto.uploadFileNative(uploadArgs);
    } else {
      await _platform.invokeMethod('uploadFileNative', uploadArgs);
    }

    onRecordSuccess(systemId, relPath, hash);
  }

  Future<void> downloadFile(
    String remotePath, 
    String localBasePath, 
    String relPath, {
    required String systemId, 
    required int fileSize, 
    required Function(String, String, String) onRecordSuccess,
    String? remoteHash, 
    int? updatedAt, 
    dynamic serverBlocks, 
    String? localUri
  }) async {
    final baseUrl = await _apiClient.getBaseUrl();
    final token = await _apiClient.getToken();
    final masterKey = await _apiClient.getEncryptionKey();
    List<int>? patchIndices;
    
    if (localUri != null && serverBlocks != null) {
       try {
       final String localBlocksJson = (Platform.isLinux || Platform.isWindows || Platform.isMacOS)
           ? await DartNativeCrypto.calculateBlockHashes(localUri, masterKey: masterKey)
           : await _platform.invokeMethod('calculateBlockHashes', {'path': localUri, 'masterKey': masterKey});

       final List localHashes = json.decode(localBlocksJson);
       final List remoteHashes = serverBlocks is String ? json.decode(serverBlocks) : serverBlocks;
       final dirty = <int>[];
       for (int i = 0; i < remoteHashes.length; i++) { if (i >= localHashes.length || localHashes[i] != remoteHashes[i]) { dirty.add(i); } }
       if (dirty.isNotEmpty && dirty.length < remoteHashes.length) { patchIndices = dirty; }
       } catch (e) {
         print('⚠️ Block Hash calculation failed for $localUri. Falling back to full download. Error: $e');
       }
    }
    
    final downloadUrl = (patchIndices != null) ? '$baseUrl/api/v1/blocks/download' : '$baseUrl/api/v1/download';

    final downloadArgs = { 
      'url': downloadUrl, 
      'token': token, 
      'masterKey': masterKey, 
      'remoteFilename': remotePath, 
      'uri': localBasePath, 
      'localFilename': relPath, 
      'updatedAt': updatedAt, 
      'patchIndices': patchIndices, 
      'fileSize': fileSize 
    };

    if (Platform.isLinux || Platform.isWindows || Platform.isMacOS) {
      await DartNativeCrypto.downloadFileNative(downloadArgs);
    } else {
      await _platform.invokeMethod('downloadFileNative', downloadArgs);
    }

    if (remoteHash != null) {
      onRecordSuccess(systemId, relPath, remoteHash);
    }  
  }

  Future<void> restoreVersion(
    String remotePath, 
    String versionId, 
    String localBasePath, 
    String relPath, 
    int fileSize
  ) async {
    final baseUrl = await _apiClient.getBaseUrl();
    final token = await _apiClient.getToken();
    final masterKey = await _apiClient.getEncryptionKey();

    final args = {
      'url': '$baseUrl/api/v1/versions/restore',
      'token': token,
      'masterKey': masterKey,
      'remoteFilename': remotePath,
      'versionId': versionId,
      'uri': localBasePath,
      'localFilename': relPath,
      'fileSize': fileSize
    };

    if (Platform.isLinux || Platform.isWindows || Platform.isMacOS) {
      await DartNativeCrypto.downloadFileNative(args);
    } else {
      await _platform.invokeMethod('downloadFileNative', args);
    }
  }
}
