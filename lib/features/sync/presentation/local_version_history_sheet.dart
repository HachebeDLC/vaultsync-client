import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../services/local_versioning_service.dart';

class LocalVersionHistorySheet extends ConsumerStatefulWidget {
  final String systemId;
  final String filePath;
  final String effectivePath;
  final String fileName;

  const LocalVersionHistorySheet({
    super.key,
    required this.systemId,
    required this.filePath,
    required this.effectivePath,
    required this.fileName,
  });

  @override
  ConsumerState<LocalVersionHistorySheet> createState() => _LocalVersionHistorySheetState();
}

class _LocalVersionHistorySheetState extends ConsumerState<LocalVersionHistorySheet> {
  bool _isLoading = true;
  bool _isRestoring = false;
  List<Map<String, dynamic>> _versions = [];

  @override
  void initState() {
    super.initState();
    _loadVersions();
  }

  Future<void> _loadVersions() async {
    final service = ref.read(localVersioningServiceProvider);
    final versions = await service.getVersions(widget.systemId, widget.filePath);
    if (mounted) {
      setState(() {
        _versions = versions;
        _isLoading = false;
      });
    }
  }

  Future<void> _restoreVersion(String versionId, int timestamp) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Restore Snapshot?'),
        content: Text('Are you sure you want to restore the snapshot from ${DateFormat('yyyy-MM-dd HH:mm').format(DateTime.fromMillisecondsSinceEpoch(timestamp))}?\n\nThe current live file will be backed up to the .undo folder.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Restore', style: TextStyle(color: Colors.red))),
        ],
      ),
    );

    if (confirm != true || !mounted) return;

    setState(() {
      _isRestoring = true;
    });

    final service = ref.read(localVersioningServiceProvider);
    final success = await service.safeRestore(widget.systemId, versionId, widget.filePath, widget.effectivePath);

    if (mounted) {
      setState(() {
        _isRestoring = false;
      });
      Navigator.pop(context, success);
    }
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: MediaQuery.of(context).size.height * 0.6,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Text(
                  'Local Snapshots: ${widget.fileName}',
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(context)),
            ],
          ),
          const Divider(),
          if (_isRestoring)
            const Expanded(
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    CircularProgressIndicator(),
                    SizedBox(height: 16),
                    Text('Reconstructing file from deltas...'),
                  ],
                ),
              ),
            )
          else if (_isLoading)
            const Expanded(child: Center(child: CircularProgressIndicator()))
          else if (_versions.isEmpty)
            const Expanded(
              child: Center(
                child: Text('No local snapshots available for this file.', style: TextStyle(color: Colors.grey)),
              ),
            )
          else
            Expanded(
              child: ListView.builder(
                itemCount: _versions.length,
                itemBuilder: (context, index) {
                  final version = _versions[index];
                  final timestamp = version['timestamp'] as int;
                  final size = version['size'] as int;
                  final date = DateTime.fromMillisecondsSinceEpoch(timestamp);
                  
                  return Card(
                    margin: const EdgeInsets.only(bottom: 8),
                    child: ListTile(
                      leading: const Icon(Icons.restore, color: Colors.blue),
                      title: Text(DateFormat('MMM dd, yyyy - HH:mm:ss').format(date)),
                      subtitle: Text('Full File Size: ${_formatSize(size)}'),
                      trailing: OutlinedButton(
                        onPressed: () => _restoreVersion(version['id'], timestamp),
                        child: const Text('Restore'),
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
}
