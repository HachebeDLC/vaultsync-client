import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:typed_data';
import 'dart:isolate';
import 'dart:async';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:crypto/crypto.dart';
import 'package:pointycastle/export.dart';
import 'storage/secure_storage_wrapper.dart';

class ApiException implements Exception {
  final int statusCode;
  final String message;

  ApiException(this.statusCode, this.message);

  @override
  String toString() => 'ApiException: HTTP $statusCode: $message';
}

class ApiClient {
  final http.Client _client;
  
  ApiClient({http.Client? client}) : _client = client ?? http.Client();

  // On Linux, libsecret (keyring/kwallet) is frequently unavailable or locked
  // (Steam Deck game mode, minimal WMs, etc.). Never touch SecureStorageWrapper
  // there so the native plugin is never invoked and libsecret is never touched.
  static final bool _useSecureStorage = !Platform.isLinux;

  String? _cachedToken;
  String? _cachedRefreshToken;
  Completer<bool>? _refreshCompleter;
  Function()? _onForceLogout;

  void setForceLogoutCallback(Function() callback) {
    _onForceLogout = callback;
  }

  Future<String?> getBaseUrl() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('api_base_url');
  }

  Future<void> setBaseUrl(String url) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('api_base_url', url);
  }

  Future<String?> _secureRead(String key) async {
    if (!_useSecureStorage) {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString('fallback_$key');
    }

    final value = await SecureStorageWrapper.read(key);
    if (value != null) return value;
    
    // Fallback if secure read failed
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('fallback_$key');
  }

  Future<void> _secureWrite(String key, String value) async {
    if (!_useSecureStorage) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('fallback_$key', value);
      return;
    }

    await SecureStorageWrapper.write(key, value);
    // Always write to fallback as well for reliability on Linux
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('fallback_$key', value);
  }

  Future<void> _secureDelete(String key) async {
    if (!_useSecureStorage) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('fallback_$key');
      return;
    }

    await SecureStorageWrapper.delete(key);
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('fallback_$key');
  }

  Future<String?> getToken() async {
    if (_cachedToken != null) return _cachedToken;
    _cachedToken = await _secureRead('auth_token');
    return _cachedToken;
  }

  Future<void> setToken(String token) async {
    await _secureWrite('auth_token', token);
    _cachedToken = token;
  }

  Future<String?> getRefreshToken() async {
    if (_cachedRefreshToken != null) return _cachedRefreshToken;
    _cachedRefreshToken = await _secureRead('refresh_token');
    return _cachedRefreshToken;
  }

  Future<void> setRefreshToken(String token) async {
    await _secureWrite('refresh_token', token);
    _cachedRefreshToken = token;
  }

  Future<void> clearToken() async {
    await _secureDelete('auth_token');
    await _secureDelete('refresh_token');
    await _secureDelete('master_key');
    await _secureDelete('user_metadata');
    _cachedToken = null;
    _cachedRefreshToken = null;
  }

  Future<void> setUserMetadata(Map<String, dynamic> metadata) async {
    await _secureWrite('user_metadata', json.encode(metadata));
  }

  Future<Map<String, dynamic>?> getUserMetadata() async {
    final raw = await _secureRead('user_metadata');
    if (raw == null) return null;
    try {
      return json.decode(raw);
    } catch (_) {
      return null;
    }
  }

  Future<bool> isConfigured() async {
    final url = await getBaseUrl();
    return url != null && url.isNotEmpty;
  }

  Future<Uri> _buildUri(String endpoint) async {
    final baseUrl = await getBaseUrl();
    if (baseUrl == null || baseUrl.isEmpty) {
      throw StateError('VaultSync Server URL is not configured. Please complete setup.');
    }
    return Uri.parse('$baseUrl$endpoint');
  }

  Future<Map<String, String>> _getHeaders({bool includeJson = true}) async {
    final token = await getToken();
    return {
      if (includeJson) 'Content-Type': 'application/json',
      if (token != null) 'Authorization': 'Bearer $token',
    };
  }

  Future<Map<String, dynamic>> _handleResponse(http.Response response, Future<Map<String, dynamic>> Function() retry) async {
    if (response.statusCode == 401) {
      // If a refresh is already in flight, wait for it rather than throwing immediately.
      // Without this, concurrent requests that all get 401 would skip the retry and
      // propagate 401 errors that look like a real auth failure to the rest of the app.
      final success = _refreshCompleter != null
          ? await _refreshCompleter!.future
          : await refreshAccessToken();
      if (success) return await retry();
    }

    if (response.statusCode != 200 && response.statusCode != 201) {
      throw ApiException(response.statusCode, response.body.length > 100 ? response.body.substring(0, 100) : response.body);
    }
    return json.decode(response.body);
  }

  Future<bool> refreshAccessToken() async {
    if (_refreshCompleter != null) return _refreshCompleter!.future;
    
    _refreshCompleter = Completer<bool>();
    try {
      developer.log('AUTH: Attempting to refresh access token', name: 'VaultSync', level: 800);
      final refreshToken = await getRefreshToken();
      if (refreshToken == null) {
        developer.log('AUTH: No refresh token found', name: 'VaultSync', level: 1000);
        await clearToken();
        _onForceLogout?.call();
        _refreshCompleter!.complete(false);
        return false;
      }

      final response = await _client.post(
        await _buildUri('/refresh'),
        headers: {'Content-Type': 'application/json'},
        body: json.encode({'refresh_token': refreshToken}),
      );

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        await setToken(data['token']);
        if (data['refresh_token'] != null) {
          await setRefreshToken(data['refresh_token']);
        }
        developer.log('AUTH: Access token refreshed successfully', name: 'VaultSync', level: 800);
        _refreshCompleter!.complete(true);
        return true;
      } else {
        developer.log('AUTH: Refresh failed (${response.statusCode}): ${response.body}', name: 'VaultSync', level: 1000);
        // If refresh fails with 401 or 403, we are permanently logged out
        if (response.statusCode == 401 || response.statusCode == 403) {
          await clearToken();
          _onForceLogout?.call();
        }
        _refreshCompleter!.complete(false);
        return false;
      }
    } catch (e) {
      developer.log('AUTH: Refresh error', name: 'VaultSync', level: 1000, error: e);
      _refreshCompleter?.complete(false);
      return false;
    } finally {
      _refreshCompleter = null;
    }
  }

  Future<Map<String, dynamic>> get(String endpoint, {Map<String, String>? queryParams}) async {
    return await _request(() async {
      var uri = await _buildUri(endpoint);
      if (queryParams != null) {
        uri = uri.replace(queryParameters: queryParams);
      }
      return await _client.get(
        uri,
        headers: await _getHeaders(includeJson: false),
      );
    });
  }

  Future<Map<String, dynamic>> post(String endpoint, {Map<String, dynamic>? body}) async {
    return await _request(() async {
      return await _client.post(
        await _buildUri(endpoint),
        headers: await _getHeaders(),
        body: json.encode(body),
      );
    });
  }

  Future<Map<String, dynamic>> delete(String endpoint, {Map<String, dynamic>? body}) async {
    return await _request(() async {
      return await _client.delete(
        await _buildUri(endpoint),
        headers: await _getHeaders(),
        body: body != null ? json.encode(body) : null,
      );
    });
  }

  Future<Map<String, dynamic>> _request(Future<http.Response> Function() call) async {
    final response = await call();
    return await _handleResponse(response, () async {
      final retryResponse = await call();
      if (retryResponse.statusCode != 200 && retryResponse.statusCode != 201) {
        throw ApiException(retryResponse.statusCode, retryResponse.body);
      }
      return json.decode(retryResponse.body);
    });
  }

  Future<http.Response> postRaw(String endpoint, {dynamic body}) async {
    final response = await _client.post(
      await _buildUri(endpoint),
      headers: await _getHeaders(includeJson: false),
      body: body,
    );
    if (response.statusCode == 401) {
      final success = _refreshCompleter != null
          ? await _refreshCompleter!.future
          : await refreshAccessToken();
      if (success) return await postRaw(endpoint, body: body);
    }
    return response;
  }

  Future<http.Response> postJsonRaw(String endpoint, Map<String, dynamic> body) async {
    final response = await _client.post(
      await _buildUri(endpoint),
      headers: await _getHeaders(),
      body: json.encode(body),
    );
    if (response.statusCode == 401) {
      final success = _refreshCompleter != null
          ? await _refreshCompleter!.future
          : await refreshAccessToken();
      if (success) return await postJsonRaw(endpoint, body);
    }
    return response;
  }

  Future<http.Response> postForm(String endpoint, Map<String, String> fields) async {
    final response = await _sendForm(endpoint, fields);
    if (response.statusCode == 401) {
      final success = _refreshCompleter != null
          ? await _refreshCompleter!.future
          : await refreshAccessToken();
      if (success) return await _sendForm(endpoint, fields);
    }
    return response;
  }

  Future<http.Response> _sendForm(String endpoint, Map<String, String> fields) async {
    var request = http.MultipartRequest('POST', await _buildUri(endpoint));
    final token = await getToken();
    if (token != null) request.headers['Authorization'] = 'Bearer $token';
    request.fields.addAll(fields);
    final streamedResponse = await _client.send(request);
    return await http.Response.fromStream(streamedResponse);
  }

  Future<void> postMultipart(String endpoint, String filePath, String remotePath, {int? updatedAt, bool? force, String? deviceName, String? hash}) async {
    final response = await _sendMultipart(endpoint, filePath, remotePath, updatedAt: updatedAt, force: force, deviceName: deviceName, hash: hash);
    if (response.statusCode == 401) {
      final success = _refreshCompleter != null
          ? await _refreshCompleter!.future
          : await refreshAccessToken();
      if (success) {
        final retryResp = await _sendMultipart(endpoint, filePath, remotePath, updatedAt: updatedAt, force: force, deviceName: deviceName, hash: hash);
        if (retryResp.statusCode != 200 && retryResp.statusCode != 201) {
          throw ApiException(retryResp.statusCode, "Multipart retry failed");
        }
        return;
      }
    }
    if (response.statusCode != 200 && response.statusCode != 201) {
      throw ApiException(response.statusCode, "Multipart upload failed");
    }
  }

  Future<http.Response> _sendMultipart(String endpoint, String filePath, String remotePath, {int? updatedAt, bool? force, String? deviceName, String? hash}) async {
    var request = http.MultipartRequest('POST', await _buildUri(endpoint));
    final token = await getToken();
    if (token != null) request.headers['Authorization'] = 'Bearer $token';
    
    request.fields['path'] = remotePath;
    if (updatedAt != null) request.fields['updated_at'] = updatedAt.toString();
    if (hash != null) request.fields['hash'] = hash;
    if (deviceName != null) request.fields['device_name'] = deviceName;
    if (force == true) request.fields['force'] = 'true';
    
    request.files.add(await http.MultipartFile.fromPath('file', filePath));
    final streamedResponse = await _client.send(request);
    return await http.Response.fromStream(streamedResponse);
  }

  Future<void> deriveAndSaveMasterKey(String password, String salt) async {
    // Zero-Knowledge: The server never sees this derivation.
    // Using PBKDF2 with SHA-256 and a high iteration count.
    // Run in Isolate to avoid blocking the UI thread.
    
    final masterKey = await Isolate.run(() {
      final saltBytes = utf8.encode(salt);
      final pkcs = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64))
        ..init(Pbkdf2Parameters(Uint8List.fromList(saltBytes), 100000, 32));
      
      final masterKeyBytes = pkcs.process(Uint8List.fromList(utf8.encode(password)));
      return base64Url.encode(masterKeyBytes);
    });
    
    await _secureWrite('master_key', masterKey);
    developer.log('AUTH: Zero-Knowledge Master Key derived via PBKDF2 (100k iterations) and secured locally', name: 'VaultSync', level: 800);
  }

  Future<String?> getEncryptionKey() async {
    return await _secureRead('master_key');
  }

  Future<void> setupRecovery(String answers, String recoverySalt, List<int> questionIndices) async {
    final masterKey = await getEncryptionKey();
    if (masterKey == null) throw Exception('Master Key missing');

    // 1. Derive Recovery Key from answers
    final recoveryKey = await Isolate.run(() {
      final saltBytes = utf8.encode(recoverySalt);
      final pkcs = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64))
        ..init(Pbkdf2Parameters(Uint8List.fromList(saltBytes), 100000, 32));
      
      return pkcs.process(Uint8List.fromList(utf8.encode(answers)));
    });

    // 2. Encrypt Master Key with Recovery Key
    final masterKeyBytes = base64Url.decode(masterKey);
    
    // Convergent Encryption: IV is MD5 of the plain data
    final iv = md5.convert(masterKeyBytes).bytes;
    
    final params = PaddedBlockCipherParameters(
      ParametersWithIV(KeyParameter(Uint8List.fromList(recoveryKey)), Uint8List.fromList(iv)),
      null,
    );
    
    final cipher = PaddedBlockCipher('AES/CBC/PKCS7')..init(true, params);
    final encryptedMasterKey = cipher.process(Uint8List.fromList(masterKeyBytes));
    
    // Final Payload: Metadata(Indices) + IV + EncryptedData
    // We use a pipe character '|' to separate B64 metadata from B64 crypto blob
    final metadata = base64Url.encode(utf8.encode(json.encode({'q': questionIndices})));
    final cryptoBlob = base64Url.encode(Uint8List.fromList(iv + encryptedMasterKey));
    final fullPayload = '$metadata|$cryptoBlob';

    // 3. Send to server
    await post('/api/v1/auth/recovery/setup', body: {
      'recovery_payload': fullPayload,
      'recovery_salt': recoverySalt,
    });
  }

  Future<Map<String, dynamic>> fetchRecoveryPayload(String email) async {
    return await post('/api/v1/auth/recovery/payload', body: {'email': email});
  }

  Future<void> recoverMasterKey(String answers, String recoverySalt, String fullPayload) async {
    // 1. Parse Payload
    final parts = fullPayload.split('|');
    final encryptedPayload = parts.length > 1 ? parts[1] : parts[0]; // Backward compatibility

    // 2. Derive Recovery Key from answers
    final recoveryKey = await Isolate.run(() {
      final saltBytes = utf8.encode(recoverySalt);
      final pkcs = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64))
        ..init(Pbkdf2Parameters(Uint8List.fromList(saltBytes), 100000, 32));
      
      return pkcs.process(Uint8List.fromList(utf8.encode(answers)));
    });

    // 3. Decrypt Master Key
    final payloadBytes = base64Url.decode(encryptedPayload);
    final iv = payloadBytes.sublist(0, 16);
    final ciphertext = payloadBytes.sublist(16);
    
    final params = PaddedBlockCipherParameters(
      ParametersWithIV(KeyParameter(Uint8List.fromList(recoveryKey)), Uint8List.fromList(iv)),
      null,
    );
    
    final cipher = PaddedBlockCipher('AES/CBC/PKCS7')..init(false, params);
    final masterKeyBytes = cipher.process(Uint8List.fromList(ciphertext));
    
    final masterKey = base64Url.encode(masterKeyBytes);

    // 4. Save locally
    await _secureWrite('master_key', masterKey);
    developer.log('AUTH: Master Key restored locally via Recovery Fail-Safe', name: 'VaultSync', level: 800);
  }
}
