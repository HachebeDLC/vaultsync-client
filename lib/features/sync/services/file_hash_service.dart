import 'dart:io';
import 'package:flutter/services.dart';
import '../data/file_cache.dart';
import '../data/dart_native_crypto.dart';

class FileHashService {
  final FileCache _fileCache;
  static const _platform = MethodChannel('com.vaultsync.app/launcher');

  FileHashService(this._fileCache);

  Future<String?> getCachedHash(String uri, int size, int lastModified) async {
    return _fileCache.getCachedHash(uri, size, lastModified);
  }

  Future<String> getLocalHash(String uri, int size, int lastModified, {String? precomputedHash}) async {
    String? hash = await _fileCache.getCachedHash(uri, size, lastModified);
    if (hash == null) {
      hash = precomputedHash;
      if (hash == null) {
        if (Platform.isLinux || Platform.isWindows || Platform.isMacOS) {
          hash = await DartNativeCrypto.calculateHash(uri);
        } else {
          hash = await _platform.invokeMethod<String>('calculateHash', {'path': uri});
        }
      }

      if (hash != null) {
        await _fileCache.updateCache(uri, size, lastModified, hash);
      }
    }
    return hash ?? 'unknown';
  }
}
