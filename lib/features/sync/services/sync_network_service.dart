import 'dart:developer' as developer;
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import '../../../core/services/api_client.dart';
import '../data/dart_native_crypto.dart';

class SyncNetworkService {
  final ApiClient _apiClient;
  static const _platform = MethodChannel('com.vaultsync.app/launcher');

  SyncNetworkService(this._apiClient);

  Future<dynamic> _executeNative(String methodName, Map<String, dynamic> args) async {
    final isDesktop = Platform.isLinux || Platform.isWindows || Platform.isMacOS;
    
    Future<dynamic> run() async {
      developer.log('SYNC NETWORK: Calling $methodName (RomM Key: ${args['rommKey'] != null})', name: 'VaultSync', level: 800);
      if (isDesktop) {
        if (methodName == 'uploadFileNative') {
          await DartNativeCrypto.uploadFileNative(args);
          return null;
        } else if (methodName == 'downloadFileNative') {
          await DartNativeCrypto.downloadFileNative(args);
          return true;
        }
        throw UnsupportedError('Method $methodName not supported natively.');
      } else {
        return await _platform.invokeMethod(methodName, args);
      }
    }

    try {
      return await run();
    } catch (e) {
      final errStr = e.toString();
      if (errStr.contains('HTTP 401')) {
        developer.log('SYNC NETWORK: Native 401 caught. Refreshing token and retrying...', name: 'VaultSync', level: 800);
        final success = await _apiClient.refreshAccessToken();
        if (success) {
          args['token'] = await _apiClient.getToken();
          try {
            return await run();
          } catch (retryError) {
             throw _mapNativeError(retryError);
          }
        }
        throw ApiException(401, "Session expired and could not be refreshed.");
      }
      throw _mapNativeError(e);
    }
  }

  Exception _mapNativeError(dynamic e) {
    final errStr = e.toString();
    if (errStr.contains('HTTP 403')) return ApiException(403, "Forbidden during native operation");
    if (errStr.contains('HTTP 401')) return ApiException(401, "Unauthorized during native operation");
    return e is Exception ? e : Exception(errStr);
  }

  Future<List<String>> getBlockHashes(String path, String? masterKey) async {
    if (Platform.isLinux || Platform.isWindows || Platform.isMacOS) {
      return await DartNativeCrypto.calculateBlockHashes(path, masterKey: masterKey);
    } else {
      final String jsonResult = await _platform.invokeMethod('calculateBlockHashes', {'path': path, 'masterKey': masterKey});
      return List<String>.from(json.decode(jsonResult));
    }
  }

  /// Computes block hashes and the full-file hash in a single file read.
  Future<Map<String, dynamic>> getBlockHashesAndFileHash(String path, String? masterKey) async {
    if (Platform.isLinux || Platform.isWindows || Platform.isMacOS) {
      return await DartNativeCrypto.calculateBlockHashesAndHash(path, masterKey: masterKey);
    } else {
      final String jsonResult = await _platform.invokeMethod('calculateBlockHashesAndHash', {'path': path, 'masterKey': masterKey});
      final decoded = json.decode(jsonResult);
      return {
        'blockHashes': List<String>.from(decoded['blockHashes']),
        'fileHash': decoded['fileHash'] as String,
      };
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
    String? rommKey,
    String? rommUrl,
    String? rommApiKey,
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
      } catch (e) { developer.log('Delta check failed', name: 'VaultSync', level: 900, error: e); }
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
      'dirtyIndices': dirtyIndices,
      'rommKey': rommKey,
      'rommUrl': rommUrl,
      'rommApiKey': rommApiKey
    };

    await _executeNative('uploadFileNative', uploadArgs);

    onRecordSuccess(systemId, relPath, hash);
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
         developer.log('Block Hash calculation failed for $localUri. Falling back to full download.', name: 'VaultSync', level: 900, error: e);
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

    final result = await _executeNative('downloadFileNative', downloadArgs);
    if (onRecordSuccess != null && remoteHash != null) {
        onRecordSuccess(systemId, relPath, remoteHash);
    }
    return result;
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

    return await _executeNative('downloadFileNative', args);
  }
}
