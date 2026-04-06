import 'dart:io';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'dart:developer' as developer;

/// Real implementation using FlutterSecureStorage.
/// This class is only instantiated on non-Linux platforms.
class SecureStorageWrapper {
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(
      encryptedSharedPreferences: true,
    ),
  );

  static Future<String?> read(String key) async {
    try {
      return await _storage.read(key: key);
    } catch (e) {
      developer.log('SECURE STORAGE READ FAILED: $e', name: 'VaultSync', level: 900);
      return null;
    }
  }

  static Future<void> write(String key, String value) async {
    try {
      await _storage.write(key: key, value: value);
    } catch (e) {
      developer.log('SECURE STORAGE WRITE FAILED: $e', name: 'VaultSync', level: 900);
    }
  }

  static Future<void> delete(String key) async {
    try {
      await _storage.delete(key: key);
    } catch (e) {
      developer.log('SECURE STORAGE DELETE FAILED: $e', name: 'VaultSync', level: 900);
    }
  }
}
