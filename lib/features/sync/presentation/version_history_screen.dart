import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/sync_repository.dart';
import 'package:intl/intl.dart';

class VersionHistoryScreen extends ConsumerStatefulWidget {
  final String remotePath;
  final String localBasePath;
  final String relPath;

  const VersionHistoryScreen({
    super.key,
    required this.remotePath,
    required this.localBasePath,
    required this.relPath,
  });

  @override
  ConsumerState<VersionHistoryScreen> createState() => _VersionHistoryScreenState();
}

class _VersionHistoryScreenState extends ConsumerState<VersionHistoryScreen> {
  static const _platform = MethodChannel('com.vaultsync.app/launcher');

  List<Map<String, dynamic>> _versions = [];
  List<Map<String, dynamic>> _localBackups = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadVersions();
  }

  Future<void> _loadVersions() async {
    setState(() => _isLoading = true);
    try {
      final serverVersions = await ref.read(syncRepositoryProvider).getFileVersions(widget.remotePath);
      final localBackups = await _loadLocalBackups();
      setState(() {
        _versions = serverVersions;
        _localBackups = localBackups;
        _isLoading = false;
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
        setState(() => _isLoading = false);
      }
    }
  }

  Future<List<Map<String, dynamic>>> _loadLocalBackups() async {
    if (!Platform.isAndroid) return [];
    try {
      final result = await _platform.invokeMethod('listLocalBackups', {'relPath': widget.relPath});
      return (result as List).map((e) => Map<String, dynamic>.from(e)).toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> _restoreLocalBackup(String backupId, int displayNum) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Restore Local Backup'),
        content: Text('Restore local backup #$displayNum? This will overwrite the current local save.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.orange, foregroundColor: Colors.white),
            child: const Text('RESTORE'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;
    setState(() => _isLoading = true);
    try {
      final destPath = '${ widget.localBasePath}/${widget.relPath}';
      final ok = await _platform.invokeMethod<bool>('restoreLocalBackup', {
        'backupId': backupId,
        'destPath': destPath,
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(ok == true ? '✅ Local backup restored!' : '❌ Restore failed')),
        );
        if (ok == true) Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('❌ $e')));
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _restore(String versionId, int displayNum, int fileSize) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Restore Version'),
        content: Text('Are you sure you want to restore Version $displayNum? Your current local save will be backed up before being overwritten.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.blue, foregroundColor: Colors.white),
            child: const Text('RESTORE'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      setState(() => _isLoading = true);
      try {
        await ref.read(syncRepositoryProvider).restoreVersion(
          widget.remotePath,
          versionId,
          widget.localBasePath,
          widget.relPath,
          fileSize,
        );
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('✅ Version restored successfully!')));
          Navigator.pop(context);
        }
      } catch (e) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('❌ Restore failed: $e')));
      } finally {
        if (mounted) setState(() => _isLoading = false);
      }
    }
  }

  IconData _getDeviceIcon(String device) {
    final d = device.toLowerCase();
    if (d.contains('thor') || d.contains('ace') || d.contains('pocket')) return Icons.smartphone;
    if (d.contains('pc') || d.contains('web')) return Icons.computer;
    return Icons.backup;
  }

  @override
  Widget build(BuildContext context) {
    final fileName = widget.relPath.split('/').last;

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Time Machine', style: TextStyle(fontSize: 16)),
            Text(fileName, style: const TextStyle(fontSize: 12, color: Colors.grey)),
          ],
        ),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : (_versions.isEmpty && _localBackups.isEmpty)
              ? _buildEmptyState()
              : ListView(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  children: [
                    if (_localBackups.isNotEmpty) ...[
                      const Padding(
                        padding: EdgeInsets.fromLTRB(4, 16, 4, 8),
                        child: Text('ON-DEVICE BACKUPS',
                            style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.orange)),
                      ),
                      const Padding(
                        padding: EdgeInsets.only(bottom: 8),
                        child: Text('Snapshots taken on this device just before a download overwrote your local save.',
                            style: TextStyle(fontSize: 12, color: Colors.grey)),
                      ),
                      ..._localBackups.asMap().entries.map((entry) {
                        final index = entry.key;
                        final b = entry.value;
                        final backupId = b['backup_id'] as String;
                        final date = DateTime.fromMillisecondsSinceEpoch((b['updated_at'] as num).toInt());
                        final size = ((b['size'] as num) / 1024).toStringAsFixed(1);
                        final displayNum = _localBackups.length - index;
                        return Card(
                          margin: const EdgeInsets.only(bottom: 8),
                          color: Colors.orange.withValues(alpha: 0.05),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                            side: BorderSide(color: Colors.orange.withValues(alpha: 0.3)),
                          ),
                          child: ListTile(
                            leading: const Icon(Icons.phone_android, color: Colors.orange),
                            title: Text(DateFormat('MMM d, yyyy · HH:mm').format(date.toLocal()),
                                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                            subtitle: Text('$size KB · local snapshot', style: const TextStyle(fontSize: 12)),
                            trailing: OutlinedButton(
                              onPressed: () => _restoreLocalBackup(backupId, displayNum),
                              style: OutlinedButton.styleFrom(foregroundColor: Colors.orange),
                              child: const Text('RESTORE'),
                            ),
                          ),
                        );
                      }),
                      const Divider(height: 32),
                    ],
                    if (_versions.isNotEmpty) ...[
                      const Padding(
                        padding: EdgeInsets.fromLTRB(4, 0, 4, 8),
                        child: Text('SERVER VERSIONS',
                            style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.blue)),
                      ),
                      const Padding(
                        padding: EdgeInsets.only(bottom: 8),
                        child: Text('Snapshots taken on the server before each upload overwrote the previous version.',
                            style: TextStyle(fontSize: 12, color: Colors.grey)),
                      ),
                      ..._versions.asMap().entries.map((entry) {
                        final index = entry.key;
                        final v = entry.value;
                        final versionId = v['version_id'];
                        final device = v['device_name'] ?? 'Unknown';
                        final date = DateTime.fromMillisecondsSinceEpoch((v['updated_at'] as num).toInt());
                        final size = ((v['size'] as num) / 1024).toStringAsFixed(1);
                        final displayNum = _versions.length - index;
                        return Card(
                          margin: const EdgeInsets.only(bottom: 8),
                          child: ListTile(
                            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                            leading: Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(color: Colors.blue.withValues(alpha: 0.1), shape: BoxShape.circle),
                              child: Icon(_getDeviceIcon(device), color: Colors.blue),
                            ),
                            title: Text(DateFormat('MMM d, yyyy · HH:mm').format(date.toLocal()),
                                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                            subtitle: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('Saved from $device', style: const TextStyle(fontSize: 12)),
                                Text('$size KB', style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
                              ],
                            ),
                            trailing: OutlinedButton(
                              onPressed: () => _restore(versionId, displayNum, v['size'] as int),
                              child: const Text('RESTORE'),
                            ),
                          ),
                        );
                      }),
                    ],
                  ],
                ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.history_toggle_off, size: 64, color: Colors.grey.shade400),
          const SizedBox(height: 16),
          const Text('No previous versions available.', style: TextStyle(color: Colors.grey)),
          const SizedBox(height: 8),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 48),
            child: Text('Versions are created automatically when a file is overwritten or deleted.', 
              style: TextStyle(fontSize: 12, color: Colors.grey), textAlign: TextAlign.center),
          ),
        ],
      ),
    );
  }
}
