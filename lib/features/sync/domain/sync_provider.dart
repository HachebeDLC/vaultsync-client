import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/sync_service.dart';

final syncProvider = StateNotifierProvider<SyncNotifier, SyncState>((ref) {
  final syncService = ref.watch(syncServiceProvider);
  return SyncNotifier(syncService);
});

class SyncState {
  final bool isSyncing;
  final bool isCancelled;
  final String status;
  final double progress;
  final List<Map<String, dynamic>> conflicts;

  SyncState({
    this.isSyncing = false, 
    this.isCancelled = false,
    this.status = '', 
    this.progress = 0.0,
    this.conflicts = const [],
  });

  SyncState copyWith({
    bool? isSyncing, 
    bool? isCancelled,
    String? status, 
    double? progress,
    List<Map<String, dynamic>>? conflicts,
  }) {
    return SyncState(
      isSyncing: isSyncing ?? this.isSyncing,
      isCancelled: isCancelled ?? this.isCancelled,
      status: status ?? this.status,
      progress: progress ?? this.progress,
      conflicts: conflicts ?? this.conflicts,
    );
  }
}

class SyncNotifier extends StateNotifier<SyncState> {
  final SyncService _syncService;

  SyncNotifier(this._syncService) : super(SyncState()) {
    refreshConflicts();
  }

  Future<void> refreshConflicts() async {
    try {
      final conflicts = await _syncService.getConflicts();
      state = state.copyWith(conflicts: conflicts);
    } catch (e) {
      print('Error fetching conflicts: $e');
    }
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
        isCancelled: () => state.isCancelled,
      );
      await refreshConflicts();
      
      if (state.isCancelled) {
        state = state.copyWith(status: 'Sync Cancelled', isSyncing: false, isCancelled: false);
      } else {
        state = state.copyWith(status: 'Sync Complete!', progress: 1.0, isSyncing: false);
      }
    } catch (e) {
      state = state.copyWith(status: 'Error: $e', isSyncing: false, isCancelled: false);
    }
  }

  Future<void> syncSingleSystem(String systemId, String localPath, {List<String>? ignoredFolders}) async {
    if (state.isSyncing) return;
    state = state.copyWith(isSyncing: true, isCancelled: false, status: 'Syncing $systemId...', progress: 0.0);

    try {
      // Direct call to repository via service logic
      await _syncService.syncSpecificSystem(systemId, localPath, ignoredFolders: ignoredFolders, onProgress: (msg) {
        state = state.copyWith(status: msg);
      });
      
      state = state.copyWith(status: 'Sync Complete!', progress: 1.0, isSyncing: false);
    } catch (e) {
      state = state.copyWith(status: 'Error: $e', isSyncing: false);
    }
  }

  Future<void> resolveConflict(Map<String, dynamic> conflict, bool keepLocal) async {
    try {
      await _syncService.resolveConflict(conflict, keepLocal);
      await refreshConflicts();
    } catch (e) {
      state = state.copyWith(status: 'Error resolving conflict: $e');
    }
  }

  Future<void> syncGameBeforeLaunch(String systemId, String gameId) async {
    if (state.isSyncing) return;
    state = state.copyWith(isSyncing: true, status: 'Checking cloud saves...', progress: 0.0);

    try {
      await _syncService.syncGameBeforeLaunch(systemId, gameId, onProgress: (msg) {
        state = state.copyWith(status: msg);
      });
      state = state.copyWith(status: 'Sync Complete!', progress: 1.0, isSyncing: false);
    } catch (e) {
      state = state.copyWith(status: 'Error: $e', isSyncing: false);
    }
  }

  Future<void> syncGameAfterClose(String systemId, String gameId) async {
    if (state.isSyncing) return;
    state = state.copyWith(isSyncing: true, status: 'Uploading saves...', progress: 0.0);

    try {
      await _syncService.syncGameAfterClose(systemId, gameId, onProgress: (msg) {
        state = state.copyWith(status: msg);
      });
      state = state.copyWith(status: 'Sync Complete!', progress: 1.0, isSyncing: false);
    } catch (e) {
      state = state.copyWith(status: 'Error: $e', isSyncing: false);
    }
  }

  void updateStatus(String msg) {
    state = state.copyWith(status: msg);
  }
}
