import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:workmanager/workmanager.dart';
import '../../../core/services/api_client_provider.dart';
import '../data/auth_repository.dart';

final authRepositoryProvider = Provider<AuthRepository>((ref) {
  final apiClient = ref.watch(apiClientProvider);
  return AuthRepository(apiClient);
});

final authProvider = StateNotifierProvider<AuthNotifier, User?>((ref) {
  final repository = ref.watch(authRepositoryProvider);
  return AuthNotifier(repository);
});

class AuthNotifier extends StateNotifier<User?> {
  final AuthRepository _repository;

  AuthNotifier(this._repository) : super(null);
  
  Future<void> init() async {
    state = await _repository.checkAuth();
  }

  Future<bool> login(String email, String password) async {
    final user = await _repository.login(email, password);
    state = user;
    return user != null;
  }
  
  Future<bool> register(String email, String password, String username) async {
    final user = await _repository.register(email, password, username);
    state = user;
    return user != null;
  }

  Future<void> logout() async {
    await Workmanager().cancelAll();
    await _repository.logout();
    state = null;
  }

  bool get isAuthenticated => state != null;
}
