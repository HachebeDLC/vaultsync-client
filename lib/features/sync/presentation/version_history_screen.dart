import 'package:flutter/material.dart';
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
  List<Map<String, dynamic>> _versions = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadVersions();
  }

  Future<void> _loadVersions() async {
    setState(() => _isLoading = true);
    try {
      final versions = await ref.read(syncRepositoryProvider).getFileVersions(widget.remotePath);
      setState(() {
        _versions = versions;
        _isLoading = false;
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
        setState(() => _isLoading = false);
      }
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
          widget.localRelPath,
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
          : _versions.isEmpty
              ? _buildEmptyState()
              : Column(
                  children: [
                    const Padding(
                      padding: EdgeInsets.all(16.0),
                      child: Text('Select a version to restore your save to a previous point in time.', 
                        style: TextStyle(fontSize: 13, color: Colors.grey), textAlign: TextAlign.center),
                    ),
                    Expanded(
                      child: ListView.builder(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        itemCount: _versions.length,
                        itemBuilder: (context, index) {
                          final v = _versions[index];
                          final versionId = v['version_id'];
                          final device = v['device_name'] ?? 'Unknown';
                          final date = DateTime.fromMillisecondsSinceEpoch(v['updated_at']);
                          final size = (v['size'] / 1024).toStringAsFixed(1);
                          final displayNum = _versions.length - index;

                          return Card(
                            margin: const EdgeInsets.only(bottom: 12),
                            child: ListTile(
                              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                              leading: Container(
                                padding: const EdgeInsets.all(8),
                                decoration: BoxDecoration(color: Colors.blue.withOpacity(0.1), shape: BoxShape.circle),
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
                                onPressed: () => _restore(versionId, displayNum, v['size']),
                                child: const Text('RESTORE'),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
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
