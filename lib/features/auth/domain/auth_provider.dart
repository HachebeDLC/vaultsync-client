import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:workmanager/workmanager.dart';
import '../../../core/services/api_client_provider.dart';
import '../data/auth_repository.dart';
import '../../sync/services/sync_event_service.dart';

final authRepositoryProvider = Provider<AuthRepository>((ref) {
  final apiClient = ref.watch(apiClientProvider);
  return AuthRepository(apiClient);
});

final authProvider = StateNotifierProvider<AuthNotifier, User?>((ref) {
  final repository = ref.watch(authRepositoryProvider);
  final eventService = ref.watch(syncEventServiceProvider);
  return AuthNotifier(repository, eventService);
});

class AuthNotifier extends StateNotifier<User?> {
  final AuthRepository _repository;
  final SyncEventService _eventService;

  AuthNotifier(this._repository, this._eventService) : super(null);
  
  Future<void> init() async {
    // Register before checkAuth so the background network call it launches
    // can trigger force-logout if the token is already dead.
    _repository.setForceLogoutCallback(_forceLogout);
    state = await _repository.checkAuth();
    if (state != null) _eventService.startListening();
  }

  void _forceLogout() {
    forceLogout();
  }

  Future<void> forceLogout() async {
    if (Platform.isAndroid || Platform.isIOS) {
      await Workmanager().cancelAll();
    }
    _eventService.stopListening();
    await _repository.clearLocalAuth();
    state = null;
  }

  Future<bool> login(String email, String password) async {
    final user = await _repository.login(email, password);
    state = user;
    if (user != null) _eventService.startListening();
    return user != null;
  }
  
  Future<bool> register(String email, String password, String username) async {
    final user = await _repository.register(email, password, username);
    state = user;
    if (user != null) _eventService.startListening();
    return user != null;
  }

  Future<void> logout() async {
    if (Platform.isAndroid || Platform.isIOS) {
      await Workmanager().cancelAll();
    }
    _eventService.stopListening();
    await _repository.logout();
    state = null;
  }

  bool get isAuthenticated => state != null;
}
