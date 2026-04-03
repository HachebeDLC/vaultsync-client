import 'dart:developer' as developer;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/sync_service.dart';
import '../data/sync_repository.dart';
import '../domain/sync_log_provider.dart';
import '../../auth/domain/auth_provider.dart';
import '../../../core/services/api_client_provider.dart';
import '../../../core/errors/error_mapper.dart';

final pendingOfflineJobsCountProvider = FutureProvider<int>((ref) async {
  final db = ref.watch(syncStateDatabaseProvider);
  final jobs = await db.getPendingOfflineJobs();
  return jobs.length;
});

final syncProvider = StateNotifierProvider<SyncNotifier, SyncState>((ref) {
  final syncService = ref.watch(syncServiceProvider);
  return SyncNotifier(syncService, ref);
});

class SyncState {
  final bool isSyncing;
  final bool isCancelled;
  final String status;
  final double progress;
  final List<Map<String, dynamic>> conflicts;
  final List<UserFacingError> syncErrors;

  SyncState({
    this.isSyncing = false, 
    this.isCancelled = false,
    this.status = '', 
    this.progress = 0.0,
    this.conflicts = const [],
    this.syncErrors = const [],
  });

  SyncState copyWith({
    bool? isSyncing, 
    bool? isCancelled,
    String? status, 
    double? progress,
    List<Map<String, dynamic>>? conflicts,
    List<UserFacingError>? syncErrors,
  }) {
    return SyncState(
      isSyncing: isSyncing ?? this.isSyncing,
      isCancelled: isCancelled ?? this.isCancelled,
      status: status ?? this.status,
      progress: progress ?? this.progress,
      conflicts: conflicts ?? this.conflicts,
      syncErrors: syncErrors ?? this.syncErrors,
    );
  }
}

class SyncNotifier extends StateNotifier<SyncState> {
  final SyncService _syncService;
  final Ref _ref;

  SyncNotifier(this._syncService, this._ref) : super(SyncState()) {
    refreshConflicts();
  }

  Future<void> refreshConflicts() async {
    try {
      final conflicts = await _syncService.getConflicts();
      state = state.copyWith(conflicts: conflicts);
    } catch (e) {
      developer.log('Error fetching conflicts', name: 'VaultSync', level: 900, error: e);
      _addError(e, systemId: 'All');
    }
  }

  void _addError(dynamic error, {String systemId = 'All'}) {
    final userError = ErrorMapper.map(error);
    state = state.copyWith(syncErrors: [...state.syncErrors, userError]);
    
    String? actionLabel;
    switch (userError.action) {
      case SyncAction.login: 
        actionLabel = 'Login'; 
        // Only trigger logout if we actually lost the session permanently
        _ref.read(apiClientProvider).getToken().then((token) {
          if (token == null) {
            developer.log('SYNC: Session is terminal. Force logging out.', name: 'VaultSync', level: 1000);
            _ref.read(authProvider.notifier).forceLogout();
          } else {
            developer.log('SYNC: 401 occurred but token exists. Refresh likely handled it.', name: 'VaultSync', level: 800);
          }
        });
        break;
      case SyncAction.openShizuku: actionLabel = 'Fix Shizuku'; break;
      case SyncAction.checkNetwork: actionLabel = 'Retry'; break;
      case SyncAction.reselectFolder: actionLabel = 'Settings'; break;
      default: break;
    }

    _ref.read(syncLogProvider.notifier).addLog(
      systemId, 
      userError.message, 
      isError: true, 
      errorTitle: userError.title,
      actionLabel: actionLabel
    );
  }

  void clearErrors() {
    state = state.copyWith(syncErrors: const []);
  }

  void cancelSync() {
    if (state.isSyncing) {
      state = state.copyWith(isCancelled: true, status: 'Cancelling...');
    }
  }

  Future<void> sync() async {
    if (state.isSyncing) return;
    state = state.copyWith(isSyncing: true, isCancelled: false, status: 'Initializing...', progress: 0.0);

    try {
      await _syncService.runSync(
        onProgress: (msg) {
          state = state.copyWith(status: msg);
        },
        onError: (msg) => _addError(msg, systemId: 'All'),
        isCancelled: () => state.isCancelled,
      );
      await refreshConflicts();
      
      if (state.isCancelled) {
        state = state.copyWith(status: 'Sync Cancelled', isSyncing: false, isCancelled: false);
      } else {
        state = state.copyWith(status: 'Sync Complete!', progress: 1.0, isSyncing: false);
      }
    } catch (e) {
      final userError = ErrorMapper.map(e);
      state = state.copyWith(status: 'Error: ${userError.title}', isSyncing: false, isCancelled: false);
      _addError(e, systemId: 'All');
    }
  }

  Future<void> syncSingleSystem(String systemId, String localPath, {List<String>? ignoredFolders}) async {
    if (state.isSyncing) return;
    state = state.copyWith(isSyncing: true, isCancelled: false, status: 'Syncing $systemId...', progress: 0.0);

    try {
      // Direct call to repository via service logic
      await _syncService.syncSpecificSystem(systemId, localPath, ignoredFolders: ignoredFolders, onProgress: (msg) {
        state = state.copyWith(status: msg);
      }, onError: (msg) => _addError(msg, systemId: systemId));
      
      state = state.copyWith(status: 'Sync Complete!', progress: 1.0, isSyncing: false);
    } catch (e) {
      final userError = ErrorMapper.map(e);
      state = state.copyWith(status: 'Error: ${userError.title}', isSyncing: false);
      _addError(e, systemId: systemId);
    }
  }

  Future<void> resolveConflict(Map<String, dynamic> conflict, bool keepLocal) async {
    try {
      await _syncService.resolveConflict(conflict['path'], keepLocal);
      await refreshConflicts();
    } catch (e) {
      state = state.copyWith(status: 'Error resolving conflict: $e');
      _addError(e, systemId: 'All');
    }
  }

  Future<void> syncGameBeforeLaunch(String systemId, String gameId) async {
    if (state.isSyncing) return;
    state = state.copyWith(isSyncing: true, status: 'Checking cloud saves...', progress: 0.0);

    try {
      await _syncService.syncGameBeforeLaunch(systemId, gameId, onProgress: (msg) {
        state = state.copyWith(status: msg);
      }, onError: (msg) => _addError(msg, systemId: systemId));
      state = state.copyWith(status: 'Sync Complete!', progress: 1.0, isSyncing: false);
    } catch (e) {
      final userError = ErrorMapper.map(e);
      state = state.copyWith(status: 'Error: ${userError.title}', isSyncing: false);
      _addError(e, systemId: systemId);
    }
  }

  Future<void> syncGameAfterClose(String systemId, String gameId) async {
    if (state.isSyncing) return;
    state = state.copyWith(isSyncing: true, status: 'Uploading saves...', progress: 0.0);

    try {
      await _syncService.syncGameAfterClose(systemId, gameId);
      state = state.copyWith(status: 'Sync Complete!', progress: 1.0, isSyncing: false);
    } catch (e) {
      state = state.copyWith(status: 'Error: $e', isSyncing: false);
    }
  }

  void updateStatus(String msg) {
    state = state.copyWith(status: msg);
  }
}
