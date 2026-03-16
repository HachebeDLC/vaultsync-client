import 'dart:convert';
import 'dart:typed_data';
import 'dart:isolate';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:crypto/crypto.dart';
import 'package:pointycastle/export.dart';

class ApiClient {
  final _secureStorage = const FlutterSecureStorage(
    aOptions: AndroidOptions(
      encryptedSharedPreferences: true,
    ),
  );

  Future<String?> getBaseUrl() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('api_base_url');
  }

  Future<void> setBaseUrl(String url) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('api_base_url', url);
  }

  Future<String?> getToken() async {
    return await _secureStorage.read(key: 'auth_token');
  }

  Future<void> setToken(String token) async {
    await _secureStorage.write(key: 'auth_token', value: token);
  }

  Future<void> clearToken() async {
    await _secureStorage.delete(key: 'auth_token');
    await _secureStorage.delete(key: 'master_key');
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

  Future<Map<String, dynamic>> get(String endpoint, {Map<String, String>? queryParams}) async {
    var uri = await _buildUri(endpoint);
    if (queryParams != null) {
      uri = uri.replace(queryParameters: queryParams);
    }
    final response = await http.get(
      uri,
      headers: await _getHeaders(includeJson: false),
    );
    if (response.statusCode != 200) {
      throw Exception('HTTP ${response.statusCode}: ${response.body.length > 100 ? response.body.substring(0, 100) : response.body}');
    }
    return json.decode(response.body);
  }

  Future<Map<String, dynamic>> post(String endpoint, {Map<String, dynamic>? body}) async {
    final response = await http.post(
      await _buildUri(endpoint),
      headers: await _getHeaders(),
      body: json.encode(body),
    );
    if (response.statusCode != 200 && response.statusCode != 201) {
      throw Exception('HTTP ${response.statusCode}: ${response.body.length > 100 ? response.body.substring(0, 100) : response.body}');
    }
    return json.decode(response.body);
  }

  Future<Map<String, dynamic>> delete(String endpoint, {Map<String, dynamic>? body}) async {
    final response = await http.delete(
      await _buildUri(endpoint),
      headers: await _getHeaders(),
      body: body != null ? json.encode(body) : null,
    );
    if (response.statusCode != 200) {
      throw Exception('HTTP ${response.statusCode}: ${response.body.length > 100 ? response.body.substring(0, 100) : response.body}');
    }
    return json.decode(response.body);
  }

  Future<http.Response> postRaw(String endpoint, {dynamic body}) async {
    return await http.post(
      await _buildUri(endpoint),
      headers: await _getHeaders(includeJson: false),
      body: body,
    );
  }

  Future<http.Response> postJsonRaw(String endpoint, Map<String, dynamic> body) async {
    return await http.post(
      await _buildUri(endpoint),
      headers: await _getHeaders(),
      body: json.encode(body),
    );
  }

  Future<http.Response> postForm(String endpoint, Map<String, String> fields) async {
    var request = http.MultipartRequest('POST', await _buildUri(endpoint));
    final token = await getToken();
    if (token != null) request.headers['Authorization'] = 'Bearer $token';
    request.fields.addAll(fields);
    final streamedResponse = await request.send();
    return await http.Response.fromStream(streamedResponse);
  }

  Future<void> postMultipart(String endpoint, String filePath, String remotePath, {int? updatedAt, bool? force, String? deviceName, String? hash}) async {
    var request = http.MultipartRequest('POST', await _buildUri(endpoint));
    final token = await getToken();
    if (token != null) request.headers['Authorization'] = 'Bearer $token';
    
    request.fields['path'] = remotePath;
    if (updatedAt != null) request.fields['updated_at'] = updatedAt.toString();
    if (hash != null) request.fields['hash'] = hash;
    if (deviceName != null) request.fields['device_name'] = deviceName;
    if (force == true) request.fields['force'] = 'true';
    
    request.files.add(await http.MultipartFile.fromPath('file', filePath));
    await request.send();
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
    
    await _secureStorage.write(key: 'master_key', value: masterKey);
    print('🔐 AUTH: Zero-Knowledge Master Key derived via PBKDF2 (100k iterations) and secured locally.');
  }

  Future<String?> getEncryptionKey() async {
    return await _secureStorage.read(key: 'master_key');
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
    await _secureStorage.write(key: 'master_key', value: masterKey);
    print('🔐 AUTH: Master Key restored locally via Recovery Fail-Safe.');
  }
}
