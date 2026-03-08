import '../../../core/services/api_client.dart';

class AuthRepository {
  final ApiClient _apiClient;

  AuthRepository(this._apiClient);

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

  Future<void> logout() async {
    await _apiClient.clearToken();
  }
  
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
}

class User {
  final String id;
  final String email;

  User({required this.id, required this.email});
}