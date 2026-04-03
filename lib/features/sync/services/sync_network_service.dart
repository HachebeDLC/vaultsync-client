import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import '../../../core/services/api_client.dart';
import '../data/dart_native_crypto.dart';

class SyncNetworkService {
  final ApiClient _apiClient;
  static const _platform = MethodChannel('com.vaultsync.app/launcher');

  SyncNetworkService(this._apiClient);

  Future<List<String>> getBlockHashes(String path, String? masterKey) async {
    if (Platform.isLinux || Platform.isWindows || Platform.isMacOS) {
      return await DartNativeCrypto.calculateBlockHashes(path, masterKey: masterKey);
    } else {
      final String jsonResult = await _platform.invokeMethod('calculateBlockHashes', {'path': path, 'masterKey': masterKey});
      return List<String>.from(json.decode(jsonResult));
    }
  }

  Future<void> uploadFile(
    String path, 
    String remotePath, {
    required String systemId, 
    required String relPath, 
    required String deviceName,
    required Function(String, String, String) onRecordSuccess,
    String? plainHash, 
    List<String>? localBlockHashes,
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
      final List<String> hashes = localBlockHashes ?? await getBlockHashes(path, masterKey);

      try {
        final checkResult = await _apiClient.post('/api/v1/blocks/check', body: {'path': remotePath, 'blocks': hashes});
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
      try {
        await DartNativeCrypto.uploadFileNative(uploadArgs);
      } catch (e) {
        await _handleNativeError(e);
      }
    } else {
      try {
        await _platform.invokeMethod('uploadFileNative', uploadArgs);
      } catch (e) {
        await _handleNativeError(e);
      }
    }

    onRecordSuccess(systemId, relPath, hash);
  }

  Future<void> _handleNativeError(dynamic e) async {
    final errStr = e.toString();
    if (errStr.contains('HTTP 401')) {
      // Proactively trigger refresh which will fire force-logout if it fails
      await _apiClient.refreshAccessToken();
      throw ApiException(401, "Session expired during native operation");
    }
    if (errStr.contains('HTTP 403')) {
      throw ApiException(403, "Forbidden during native operation");
    }
    throw e;
  }

  Future<dynamic> downloadFile(
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
       final List<String> localHashes = await getBlockHashes(localUri, masterKey);
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
      try {
        await DartNativeCrypto.downloadFileNative(downloadArgs);
        return true;
      } catch (e) {
        await _handleNativeError(e);
      }
    } else {
      try {
        return await _platform.invokeMethod('downloadFileNative', downloadArgs);
      } catch (e) {
        await _handleNativeError(e);
      }
    }
  }

  Future<dynamic> restoreVersion(
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
      try {
        await DartNativeCrypto.downloadFileNative(args);
        return true;
      } catch (e) {
        await _handleNativeError(e);
      }
    } else {
      try {
        return await _platform.invokeMethod('downloadFileNative', args);
      } catch (e) {
        await _handleNativeError(e);
      }
    }
  }
}
