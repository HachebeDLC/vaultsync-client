import 'dart:io';
import 'package:flutter/services.dart';
import '../data/file_cache.dart';
import '../data/dart_native_crypto.dart';

class FileHashService {
  final FileCache _fileCache;
  static const _platform = MethodChannel('com.vaultsync.app/launcher');

  FileHashService(this._fileCache);

  Future<String> getLocalHash(String uri, int size, int lastModified, {bool forceFresh = false}) async {
    // SAF content:// URIs on Android have unreliable lastModified for files in
    // Android/data/ — the MediaStore cursor doesn't update it when the owning app
    // writes to its own files. Skip the cache so the hash is always computed from
    // actual file bytes rather than a stale cache entry.
    String? hash = forceFresh ? null : await _fileCache.getCachedHash(uri, size, lastModified);
    if (hash == null) {
      if (Platform.isLinux || Platform.isWindows || Platform.isMacOS) {
        hash = await DartNativeCrypto.calculateHash(uri);
      } else {
        hash = await _platform.invokeMethod<String>('calculateHash', {'path': uri});
      }

      if (hash != null) {
        await _fileCache.updateCache(uri, size, lastModified, hash);
      }
    }
    return hash ?? 'unknown';
  }
}
