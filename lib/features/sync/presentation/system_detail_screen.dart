import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/sync_repository.dart';
import '../services/system_path_service.dart';
import '../domain/sync_provider.dart';
import 'version_history_screen.dart';

class SystemDetailScreen extends ConsumerStatefulWidget {
  final String systemId;

  const SystemDetailScreen({super.key, required this.systemId});

  @override
  ConsumerState<SystemDetailScreen> createState() => _SystemDetailScreenState();
}

class _SystemDetailScreenState extends ConsumerState<SystemDetailScreen> {
  List<Map<String, dynamic>>? _rawFiles;
  String? _localPath;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() => _isLoading = true);
    final pathService = ref.read(systemPathServiceProvider);
    final repo = ref.read(syncRepositoryProvider);
    
    _localPath = await pathService.getEffectivePath(widget.systemId);
    if (_localPath == null) {
       _isLoading = false;
       if (mounted) setState(() {});
       return;
    }

    final allSystems = await pathService.getEmulatorRepository().loadSystems();
    final systemConfig = allSystems.where((s) => s.system.id == widget.systemId).firstOrNull;
    final ignoredFolders = systemConfig?.system.ignoredFolders;

    try {
      final diff = await repo.diffSystem(
        widget.systemId, 
        _localPath!, 
        ignoredFolders: ignoredFolders,
      );
      setState(() {
        _rawFiles = diff;
        _isLoading = false;
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Refresh failed: $e')));
        setState(() => _isLoading = false);
      }
    }
  }

  Color _getStatusColor(String status) {
    switch (status) {
      case 'Synced': return Colors.green;
      case 'Modified': return Colors.orange;
      case 'Local Only': return Colors.blue;
      case 'Remote Only': return Colors.purple;
      default: return Colors.grey;
    }
  }

  Widget _buildFileTile(Map<String, dynamic> file) {
    final String relPath = file['relPath'];
    final String status = file['status'];
    final String type = file['type'] ?? 'Save';
    final String name = relPath.split('/').last;

    final isState = type == 'State';
    final isRetroArch = _localPath?.toLowerCase().contains('retroarch') ?? false;
    
    return ListTile(
      dense: true,
      leading: Icon(
        isState ? Icons.camera_alt_outlined : Icons.save_outlined, 
        color: _getStatusColor(status), 
        size: 18
      ),
      title: Row(
        children: [
          Expanded(child: Text(name, style: const TextStyle(fontSize: 14))),
          if (isState && isRetroArch)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.blue.withOpacity(0.1),
                borderRadius: BorderRadius.circular(4),
              ),
              child: const Text('STATE', style: TextStyle(fontSize: 8, fontWeight: FontWeight.bold, color: Colors.blue)),
            ),
        ],
      ),
      subtitle: Text(status, style: TextStyle(color: _getStatusColor(status), fontSize: 11)),
      trailing: IconButton(
        icon: const Icon(Icons.history, size: 20),
        onPressed: () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => VersionHistoryScreen(
                remotePath: file['remotePath'],
                localBasePath: _localPath!,
                relPath: relPath,
              ),
            ),
          );
        },
      ),
    );
  }

  List<Widget> _buildHierarchy(String parentPath) {
    final List<Widget> children = [];
    
    // Get immediate files and folders in this parentPath
    final itemsInPath = _rawFiles!.where((f) {
      final path = f['relPath'] as String;
      if (parentPath.isEmpty) return !path.contains('/');
      if (!path.startsWith('$parentPath/')) return false;
      final subPath = path.substring(parentPath.length + 1);
      return !subPath.contains('/');
    }).toList();

    // Sort: Folders first, then files
    itemsInPath.sort((a, b) {
       final aIsDir = a['isDirectory'] == true;
       final bIsDir = b['isDirectory'] == true;
       if (aIsDir != bIsDir) return aIsDir ? -1 : 1;
       return (a['relPath'] as String).compareTo(b['relPath'] as String);
    });

    for (final item in itemsInPath) {
      if (item['isDirectory'] == true) {
        children.add(ExpansionTile(
          leading: const Icon(Icons.folder, color: Colors.amber),
          title: Text(item['name'], style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 14)),
          childrenPadding: const EdgeInsets.only(left: 16),
          children: _buildHierarchy(item['relPath']),
        ));
      } else {
        children.add(_buildFileTile(item));
      }
    }
    
    return children;
  }

  Future<void> _syncThisSystem() async {
    if (_localPath == null) return;
    
    final pathService = ref.read(systemPathServiceProvider);
    final allSystems = await pathService.getEmulatorRepository().loadSystems();
    final systemConfig = allSystems.where((s) => s.system.id == widget.systemId).firstOrNull;
    final ignoredFolders = systemConfig?.system.ignoredFolders;

    await ref.read(syncProvider.notifier).syncSingleSystem(
      widget.systemId, 
      _localPath!, 
      ignoredFolders: ignoredFolders
    );
    
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final syncState = ref.watch(syncProvider);
    final isSyncing = syncState.isSyncing;

    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.systemId.toUpperCase()} Details'),
        actions: [
          IconButton(
            icon: const Icon(Icons.sync),
            tooltip: 'Sync This System',
            onPressed: isSyncing ? null : _syncThisSystem,
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: isSyncing ? null : _refresh,
          ),
        ],
      ),
      body: Column(
        children: [
          if (isSyncing)
            LinearProgressIndicator(
              value: syncState.progress > 0 ? syncState.progress : null,
              backgroundColor: Colors.blue.withOpacity(0.1),
            ),
          if (isSyncing)
            Container(
              padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 16),
              color: Colors.blue.withOpacity(0.1),
              width: double.infinity,
              child: Text(
                syncState.status,
                style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.blue),
                textAlign: TextAlign.center,
              ),
            ),
          Expanded(
            child: _isLoading 
                ? const Center(child: CircularProgressIndicator())
                : _rawFiles == null
                    ? const Center(child: Text('System not configured.'))
                    : _rawFiles!.isEmpty
                        ? const Center(child: Text('No files found.'))
                        : ListView(
                            padding: const EdgeInsets.all(8),
                            children: _buildHierarchy(''),
                          ),
          ),
        ],
      ),
    );
  }
}
