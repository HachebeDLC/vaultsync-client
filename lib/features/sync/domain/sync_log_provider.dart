import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';

class SyncLog {
  final String systemId;
  final String status;
  final String? errorTitle;
  final String? actionLabel;
  final DateTime timestamp;
  final bool isError;

  /// The underlying cause (exception runtimeType + message, trimmed to
  /// ~300 chars — see `buildErrorDetail` in error_mapper.dart), kept
  /// alongside the friendly [status]/[errorTitle] mapped text so a swallowed
  /// real exception is still visible in the sync history / diagnostic
  /// report. Optional and defaults to null so entries persisted by an older
  /// app version (with no `detail` key in their JSON) still load fine.
  final String? detail;

  SyncLog({
    required this.systemId,
    required this.status,
    required this.timestamp,
    this.isError = false,
    this.errorTitle,
    this.actionLabel,
    this.detail,
  });

  Map<String, dynamic> toJson() => {
    'systemId': systemId,
    'status': status,
    'timestamp': timestamp.toIso8601String(),
    'isError': isError,
    'errorTitle': errorTitle,
    'actionLabel': actionLabel,
    'detail': detail,
  };

  factory SyncLog.fromJson(Map<String, dynamic> json) => SyncLog(
    systemId: json['systemId'],
    status: json['status'],
    timestamp: DateTime.parse(json['timestamp']),
    isError: json['isError'] ?? false,
    errorTitle: json['errorTitle'],
    actionLabel: json['actionLabel'],
    detail: json['detail'], // absent in pre-existing entries -> null
  );
}

final syncLogProvider = StateNotifierProvider<SyncLogNotifier, List<SyncLog>>((ref) {
  return SyncLogNotifier();
});

class SyncLogNotifier extends StateNotifier<List<SyncLog>> {
  SyncLogNotifier() : super([]) {
    _loadLogs();
  }

  static const _key = 'sync_history_logs';

  Future<void> _loadLogs() async {
    final prefs = await SharedPreferences.getInstance();
    final data = prefs.getStringList(_key) ?? [];
    state = data.map((item) => SyncLog.fromJson(json.decode(item))).toList();
  }

  Future<void> addLog(String systemId, String status, {bool isError = false, String? errorTitle, String? actionLabel, String? detail}) async {
    if (!mounted) return;

    final log = SyncLog(
      systemId: systemId,
      status: status,
      timestamp: DateTime.now(),
      isError: isError,
      errorTitle: errorTitle,
      actionLabel: actionLabel,
      detail: detail,
    );
    
    final newState = [log, ...state].take(50).toList(); // Keep last 50 logs
    state = newState;
    
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_key, state.map((l) => json.encode(l.toJson())).toList());
  }

  Future<void> clearLogs() async {
    state = [];
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }
}
