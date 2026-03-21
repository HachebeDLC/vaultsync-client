import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../data/sync_repository.dart';
import '../services/system_path_service.dart';
import '../domain/sync_provider.dart';
import 'version_history_screen.dart';
import '../../../core/utils/responsive_layout.dart';

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
    
    return Tooltip(
      message: 'Click to view version history',
      child: ListTile(
        dense: true,
        mouseCursor: SystemMouseCursors.click,
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
          tooltip: 'Version History',
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
        onTap: () {
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
    
    // Get immediate files and dynamically generate folders in this parentPath
    final Set<String> folderNames = {};
    final List<Map<String, dynamic>> files = [];

    for (final f in _rawFiles!) {
      final path = f['relPath'] as String;
      if (parentPath.isEmpty) {
        if (!path.contains('/')) {
          files.add(f);
        } else {
          folderNames.add(path.split('/').first);
        }
      } else {
        if (path.startsWith('$parentPath/')) {
          final subPath = path.substring(parentPath.length + 1);
          if (!subPath.contains('/')) {
            files.add(f);
          } else {
            folderNames.add(subPath.split('/').first);
          }
        }
      }
    }

    final sortedFolders = folderNames.toList()..sort();
    for (final folder in sortedFolders) {
      final currentPath = parentPath.isEmpty ? folder : '$parentPath/$folder';
      children.add(ExpansionTile(
        leading: const Icon(Icons.folder, color: Colors.amber),
        title: Text(folder, style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 14)),
        childrenPadding: const EdgeInsets.only(left: 16),
        children: _buildHierarchy(currentPath),
      ));
    }

    files.sort((a, b) => (a['relPath'] as String).compareTo(b['relPath'] as String));
    for (final file in files) {
      children.add(_buildFileTile(file));
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

  Widget _getSystemIconWidget(String systemId, {double size = 28}) {
    final id = systemId.toLowerCase();
    
    // 1. Map system variants to verified clean SVG filenames
    String iconName = 'controller';
    if (id.contains('ps2') || id.contains('aethersx2') || id.contains('nethersx2') || id.contains('psx') || id.contains('ps1') || id.contains('playstation')) {
      iconName = 'playstation';
    } else if (id.contains('gba') || id.contains('gbc') || id.contains('gb') || id.contains('gameboy')) {
      iconName = 'gameboy';
    } else if (id.contains('dc') || id.contains('flycast') || id.contains('redream') || id.contains('dreamcast')) {
      iconName = 'dc';
    } else if (id.contains('gc') || id.contains('dolphin')) {
      iconName = 'gc';
    } else if (id.contains('3ds') || id.contains('citra')) {
      iconName = 'nintendo3ds';
    } else if (id.contains('ds') || id.contains('melonds')) {
      iconName = 'ds';
    } else if (id.contains('switch') || id.contains('ns') || id.contains('eden')) {
      iconName = 'nintendoswitch';
    } else if (id.contains('psp') || id.contains('ppsspp')) {
      iconName = 'psp';
    } else if (id.contains('wii')) {
      iconName = 'wii';
    } else if (id.contains('n64')) {
      iconName = 'n64';
    } else if (id.contains('nes')) {
      iconName = 'nes';
    } else if (id.contains('snes')) {
      iconName = 'snes';
    } else if (id.contains('genesis') || id.contains('megadrive')) {
      iconName = 'genesis';
    } else if (id.contains('retroarch')) {
      iconName = 'retroarch';
    }

    try {
      return SvgPicture.asset(
        'assets/systems/$iconName.svg',
        width: size,
        height: size,
        colorFilter: const ColorFilter.mode(Colors.white, BlendMode.srcIn),
        placeholderBuilder: (context) => Icon(_getFallbackIcon(id), size: size, color: Colors.white),
      );
    } catch (_) {
      return Icon(_getFallbackIcon(id), size: size, color: Colors.white);
    }
  }

  IconData _getFallbackIcon(String id) {
    if (id.contains('gba') || id.contains('gbc') || id.contains('gb')) return Icons.gamepad;
    if (id.contains('ps1') || id.contains('ps2') || id.contains('psx') || id.contains('psp')) return Icons.sports_esports;
    if (id.contains('switch') || id.contains('ns')) return Icons.switch_left;
    if (id.contains('ds') || id.contains('3ds')) return Icons.developer_board;
    if (id.contains('n64') || id.contains('gc') || id.contains('wii')) return Icons.videogame_asset;
    if (id.contains('retroarch')) return Icons.settings_input_component;
    return Icons.folder;
  }

  @override
  Widget build(BuildContext context) {
    final syncState = ref.watch(syncProvider);
    final isSyncing = syncState.isSyncing;
    final isDesktop = ResponsiveLayout.isDesktop(context);

    return Scaffold(
      appBar: AppBar(
        centerTitle: !isDesktop,
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _getSystemIconWidget(widget.systemId),
            const SizedBox(width: 12),
            Text(isDesktop ? '${widget.systemId.toUpperCase()} Management' : widget.systemId.toUpperCase()),
          ],
        ),
        actions: [
          if (isDesktop)
            Padding(
              padding: const EdgeInsets.only(right: 8.0),
              child: TextButton.icon(
                icon: const Icon(Icons.sync),
                label: const Text('SYNC NOW'),
                onPressed: isSyncing ? null : _syncThisSystem,
              ),
            )
          else
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
                        : Center(
                            child: Container(
                              constraints: BoxConstraints(maxWidth: isDesktop ? 900 : double.infinity),
                              child: ListView(
                                padding: const EdgeInsets.all(8),
                                children: _buildHierarchy(''),
                              ),
                            ),
                          ),
          ),
        ],
      ),
    );
  }
}
