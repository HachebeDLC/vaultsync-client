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

  SyncLog({
    required this.systemId,
    required this.status,
    required this.timestamp,
    this.isError = false,
    this.errorTitle,
    this.actionLabel,
  });

  Map<String, dynamic> toJson() => {
    'systemId': systemId,
    'status': status,
    'timestamp': timestamp.toIso8601String(),
    'isError': isError,
    'errorTitle': errorTitle,
    'actionLabel': actionLabel,
  };

  factory SyncLog.fromJson(Map<String, dynamic> json) => SyncLog(
    systemId: json['systemId'],
    status: json['status'],
    timestamp: DateTime.parse(json['timestamp']),
    isError: json['isError'] ?? false,
    errorTitle: json['errorTitle'],
    actionLabel: json['actionLabel'],
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

  Future<void> addLog(String systemId, String status, {bool isError = false, String? errorTitle, String? actionLabel}) async {
    if (!mounted) return;
    
    final log = SyncLog(
      systemId: systemId,
      status: status,
      timestamp: DateTime.now(),
      isError: isError,
      errorTitle: errorTitle,
      actionLabel: actionLabel,
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
