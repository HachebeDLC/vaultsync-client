import 'dart:developer' as developer;
import '../../../core/services/api_client.dart';

/// Handles user authentication, registration, and master key management.
class AuthRepository {
  final ApiClient _apiClient;

  AuthRepository(this._apiClient);

  /// Authenticates a user with email and password, and derives the local master key.
  Future<User?> login(String email, String password) async {
    try {
      final response = await _apiClient.post('/login', body: {
        'email': email,
        'password': password,
      });

      final token = response['token'];
      final refreshToken = response['refresh_token'];
      if (token != null) {
        await _apiClient.setToken(token);
        if (refreshToken != null) await _apiClient.setRefreshToken(refreshToken);
        
        final userData = response['user'];
        await _apiClient.setUserMetadata(userData);
        
        final salt = userData['salt'] ?? email; // Fallback to email for legacy users
        await _apiClient.deriveAndSaveMasterKey(password, salt);
        
        return User(id: userData['id'].toString(), email: userData['email']);
      }
      return null;
    } catch (e) {
      developer.log('Login error', name: 'VaultSync', level: 1000, error: e);
      return null;
    }
  }

  /// Registers a new user and establishes their initial encryption salt.
  Future<User?> register(String email, String password, String username) async {
    try {
      final response = await _apiClient.post('/register', body: {
        'email': email,
        'password': password,
        'username': username,
      });
      
      final token = response['token'];
      final refreshToken = response['refresh_token'];
      if (token != null) {
        await _apiClient.setToken(token);
        if (refreshToken != null) await _apiClient.setRefreshToken(refreshToken);
        
        final userData = response['user'];
        await _apiClient.setUserMetadata(userData);
        
        final salt = userData['salt'] ?? email; // Fallback to email for legacy users
        await _apiClient.deriveAndSaveMasterKey(password, salt);
        
        return User(id: userData['id'].toString(), email: userData['email']);
      }
      return null;
    } catch (e) {
      developer.log('Register error', name: 'VaultSync', level: 1000, error: e);
      return null;
    }
  }

  /// Registers a callback that is invoked when the server invalidates the session
  /// (e.g. refresh token rejected with 401). Allows the auth layer to react
  /// without ApiClient needing to know about Riverpod or navigation.
  void setForceLogoutCallback(Function() callback) {
    _apiClient.setForceLogoutCallback(callback);
  }

  /// Wipes the local session token and logs out the user.
  Future<void> logout() async {
    await _apiClient.clearToken();
  }

  /// Wipes local auth data without attempting to notify the server.
  Future<void> clearLocalAuth() async {
    await _apiClient.clearToken();
  }
  
  /// Validates the current session token against the server.
  Future<User?> checkAuth() async {
    try {
      final token = await _apiClient.getToken();
      if (token == null) return null;
      
      // Try to get cached metadata first for instant resume
      final cached = await _apiClient.getUserMetadata();
      if (cached != null) {
        // Run network check in background to verify but return cached for speed
        _apiClient.get('/auth/me').then((response) {
          _apiClient.setUserMetadata(response);
        }).catchError((e) {
          developer.log('Background CheckAuth failed', name: 'VaultSync', level: 900, error: e);
        });
        
        return User(id: cached['id'].toString(), email: cached['email']);
      }

      final response = await _apiClient.get('/auth/me');
      await _apiClient.setUserMetadata(response);
      return User(id: response['id'].toString(), email: response['email']);
    } catch (e) {
      developer.log('CheckAuth error', name: 'VaultSync', level: 900, error: e);
      return null;
    }
  }

  Future<void> setupRecovery(List<String> answers, String salt, List<int> questionIndices) async {
    // Normalize: lowercase, trimmed, joined by colon
    final normalized = answers.map((a) => a.trim().toLowerCase()).join(':');
    await _apiClient.setupRecovery(normalized, salt, questionIndices);
  }

  Future<Map<String, dynamic>> fetchRecoveryInfo(String email) async {
    return await _apiClient.fetchRecoveryPayload(email);
  }

  Future<void> recoverMasterKey(String email, List<String> answers, String salt, String fullPayload) async {
    final normalized = answers.map((a) => a.trim().toLowerCase()).join(':');
    await _apiClient.recoverMasterKey(normalized, salt, fullPayload);
  }
}

/// Represents an authenticated user account.
class User {
  final String id;
  final String email;

  User({required this.id, required this.email});
}