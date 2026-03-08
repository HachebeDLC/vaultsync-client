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

  Future<Map<String, dynamic>> get(String endpoint) async {
    final baseUrl = await getBaseUrl();
    final token = await getToken();
    final response = await http.get(
      Uri.parse('$baseUrl$endpoint'),
      headers: {
        if (token != null) 'Authorization': 'Bearer $token',
      },
    );
    if (response.statusCode != 200) {
      throw Exception('HTTP ${response.statusCode}: ${response.body.length > 100 ? response.body.substring(0, 100) : response.body}');
    }
    return json.decode(response.body);
  }

  Future<Map<String, dynamic>> post(String endpoint, {Map<String, dynamic>? body}) async {
    final baseUrl = await getBaseUrl();
    final token = await getToken();
    final response = await http.post(
      Uri.parse('$baseUrl$endpoint'),
      headers: {
        'Content-Type': 'application/json',
        if (token != null) 'Authorization': 'Bearer $token',
      },
      body: json.encode(body),
    );
    if (response.statusCode != 200 && response.statusCode != 201) {
      throw Exception('HTTP ${response.statusCode}: ${response.body.length > 100 ? response.body.substring(0, 100) : response.body}');
    }
    return json.decode(response.body);
  }

  Future<Map<String, dynamic>> delete(String endpoint, {Map<String, dynamic>? body}) async {
    final baseUrl = await getBaseUrl();
    final token = await getToken();
    final response = await http.delete(
      Uri.parse('$baseUrl$endpoint'),
      headers: {
        'Content-Type': 'application/json',
        if (token != null) 'Authorization': 'Bearer $token',
      },
      body: body != null ? json.encode(body) : null,
    );
    if (response.statusCode != 200) {
      throw Exception('HTTP ${response.statusCode}: ${response.body.length > 100 ? response.body.substring(0, 100) : response.body}');
    }
    return json.decode(response.body);
  }

  Future<http.Response> postRaw(String endpoint, {dynamic body}) async {
    final baseUrl = await getBaseUrl();
    final token = await getToken();
    return await http.post(
      Uri.parse('$baseUrl$endpoint'),
      headers: {
        if (token != null) 'Authorization': 'Bearer $token',
      },
      body: body,
    );
  }

  Future<http.Response> postJsonRaw(String endpoint, Map<String, dynamic> body) async {
    final baseUrl = await getBaseUrl();
    final token = await getToken();
    return await http.post(
      Uri.parse('$baseUrl$endpoint'),
      headers: {
        'Content-Type': 'application/json',
        if (token != null) 'Authorization': 'Bearer $token',
      },
      body: json.encode(body),
    );
  }

  Future<http.Response> postForm(String endpoint, Map<String, String> fields) async {
    final baseUrl = await getBaseUrl();
    final token = await getToken();
    var request = http.MultipartRequest('POST', Uri.parse('$baseUrl$endpoint'));
    if (token != null) request.headers['Authorization'] = 'Bearer $token';
    request.fields.addAll(fields);
    final streamedResponse = await request.send();
    return await http.Response.fromStream(streamedResponse);
  }

  Future<void> postMultipart(String endpoint, String filePath, String remotePath, {int? updatedAt, bool? force, String? deviceName, String? hash}) async {
    final baseUrl = await getBaseUrl();
    final token = await getToken();
    var request = http.MultipartRequest('POST', Uri.parse('$baseUrl$endpoint'));
    
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
}
