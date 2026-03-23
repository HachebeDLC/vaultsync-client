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
      if (token != null) {
        await _apiClient.setToken(token);
        
        final userData = response['user'];
        final salt = userData['salt'] ?? email; // Fallback to email for legacy users
        await _apiClient.deriveAndSaveMasterKey(password, salt);
        
        return User(id: userData['id'].toString(), email: userData['email']);
      }
      return null;
    } catch (e) {
      print('Login error: $e');
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
      if (token != null) {
        await _apiClient.setToken(token);
        
        final userData = response['user'];
        final salt = userData['salt'] ?? email; // Fallback to email for legacy users
        await _apiClient.deriveAndSaveMasterKey(password, salt);
        
        return User(id: userData['id'].toString(), email: userData['email']);
      }
      return null;
    } catch (e) {
      print('Register error: $e');
      return null;
    }
  }

  /// Wipes the local session token and logs out the user.
  Future<void> logout() async {
    await _apiClient.clearToken();
  }
  
  /// Validates the current session token against the server.
  Future<User?> checkAuth() async {
    try {
      final token = await _apiClient.getToken();
      if (token == null) return null;
      
      final response = await _apiClient.get('/auth/me');
      return User(id: response['id'], email: response['email']);
    } catch (e) {
      print('CheckAuth error: $e');
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