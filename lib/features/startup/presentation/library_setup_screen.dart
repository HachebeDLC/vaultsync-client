import 'package:flutter/material.dart';
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:permission_handler/permission_handler.dart';
import '../../sync/services/system_path_service.dart';
import '../../emulation/presentation/emulator_providers.dart';
import '../../emulation/domain/emulator_config.dart';
import '../../../core/utils/platform_utils.dart';

class LibrarySetupScreen extends ConsumerStatefulWidget {
  const LibrarySetupScreen({super.key});

  @override
  ConsumerState<LibrarySetupScreen> createState() => _LibrarySetupScreenState();
}

class _LibrarySetupScreenState extends ConsumerState<LibrarySetupScreen> {
  final _pathController = TextEditingController();
  bool _isScanning = false;
  List<Map<String, String>> _foundSystems = [];
  Map<String, String> _configuredPaths = {};

  @override
  void initState() {
    super.initState();
    _checkPermissions();
    _loadSavedPath();
    _loadConfiguredPaths();
  }

  Future<void> _checkPermissions() async {
    if (!Platform.isAndroid && !Platform.isIOS) return;
    
    var status = await Permission.manageExternalStorage.status;
    if (!status.isGranted) {
      status = await Permission.manageExternalStorage.request();
    }
  }

  Future<void> _loadSavedPath() async {
    final savedPath = await ref.read(systemPathServiceProvider).getLibraryPath();
    if (savedPath != null && mounted) {
      setState(() {
        _pathController.text = savedPath;
      });
    } else {
      _pathController.text = '/storage/emulated/0/Roms';
    }
  }

  Future<void> _loadConfiguredPaths() async {
    final paths = await ref.read(systemPathServiceProvider).getAllSystemPaths();
    if (mounted) {
      setState(() {
        _configuredPaths = paths;
      });
    }
  }

  Future<void> _pickGlobalFolder() async {
    String? selectedDirectory = await ref.read(systemPathServiceProvider).openDirectoryPicker();
    if (selectedDirectory != null) {
      setState(() {
        _pathController.text = selectedDirectory;
      });
      await ref.read(systemPathServiceProvider).setLibraryPath(selectedDirectory);
    }
  }

  Future<void> _scan() async {
    setState(() => _isScanning = true);
    final service = ref.read(systemPathServiceProvider);
    await service.setLibraryPath(_pathController.text);
    
    try {
      final path = _pathController.text;
      final found = await service.scanLibrary(path);
      
      // Auto-save the detected paths and configure default emulators
      if (found.isNotEmpty) {
        final systems = await ref.read(systemsProvider.future);
        for (final f in found) {
          final sid = f['systemId']!;
          final p = f['path']!;
          
          final currentPath = await service.getSystemPath(sid);
          final sysConf = systems.firstWhere((s) => s.system.id == sid);
          
          // Auto-selected mapped emulator from EmuDeck detection
          final mappedEmuId = f['emulatorId'];
          
          // If the path was never set, OR if we just found an explicit EmuDeck route, 
          // we should override it to fix any previously incorrect fallback setups.
          final isEmuDeckRoute = mappedEmuId != null && p.toLowerCase().contains('emulation/saves');
          
          if (currentPath == null || (isEmuDeckRoute && !(currentPath?.toLowerCase().contains('emulation/saves') ?? false))) {
            final supportedEmus = sysConf.emulators.where((e) => PlatformUtils.isEmulatorSupported(e.uniqueId)).toList();
            
            EmulatorInfo? selectedEmu;
            if (mappedEmuId != null && mappedEmuId.isNotEmpty) {
              selectedEmu = supportedEmus.where((e) => e.uniqueId == mappedEmuId).firstOrNull;
            }
            
            if (selectedEmu == null) {
              selectedEmu = supportedEmus.firstWhere((e) => e.defaultEmulator, orElse: () => supportedEmus.isNotEmpty ? supportedEmus.first : sysConf.emulators.first);
            }
            
            await service.setSystemEmulator(sid, selectedEmu.uniqueId);
            
            if (mappedEmuId != null && mappedEmuId.isNotEmpty) {
              await service.setSystemPath(sid, p);
            } else {
              final suggested = await service.suggestSavePath(selectedEmu, sid);
              await service.setSystemPath(sid, suggested);
            }
          }
        }
      }

      setState(() => _foundSystems = found);
      await _loadConfiguredPaths();
      ref.invalidate(systemPathsProvider);
      
      if (found.isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No systems found in that folder.')),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e')),
      );
    } finally {
      if (mounted) setState(() => _isScanning = false);
    }
  }

  Future<void> _configureSystem(String systemId) async {
    final systems = await ref.read(systemsProvider.future);
    final system = systems.firstWhere((s) => s.system.id == systemId);
    final pathService = ref.read(systemPathServiceProvider);
    
    final currentEmulatorId = await pathService.getSystemEmulator(systemId);
    final currentPath = await pathService.getSystemPath(systemId);

    if (!mounted) return;

    final supportedEmulators = system.emulators.where((e) => PlatformUtils.isEmulatorSupported(e.uniqueId)).toList();
    if (supportedEmulators.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No supported emulators found for this platform.')),
      );
      return;
    }

    final selectedEmulatorId = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Select Emulator for ${system.system.name}'),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: supportedEmulators.length,
            itemBuilder: (context, index) {
              final emu = supportedEmulators[index];
              final isSelected = emu.uniqueId == currentEmulatorId;
              return ListTile(
                title: Text(emu.name, style: TextStyle(fontWeight: isSelected ? FontWeight.bold : FontWeight.normal)),
                subtitle: Text(emu.uniqueId),
                selected: isSelected,
                trailing: isSelected ? const Icon(Icons.check, color: Colors.blue) : null,
                onTap: () => Navigator.pop(context, emu.uniqueId),
              );
            },
          ),
        ),
      ),
    );

    if (selectedEmulatorId == null) return;

    final emulator = system.emulators.firstWhere((e) => e.uniqueId == selectedEmulatorId);
    
    // First try the current configured path, then the auto-mapped EmuDeck path, then fallback to platform defaults
    final mappedPath = _foundSystems.where((f) => f['systemId'] == systemId).firstOrNull?['path'];
    String initialPath = currentPath ?? mappedPath ?? await pathService.suggestSavePath(emulator, systemId);

    if (!mounted) return;

    final pathController = TextEditingController(text: initialPath);
    final confirmedPath = await showDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Configure Save Path'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Emulator: ${emulator.name}', style: const TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 16),
                const Text('Save Folder:'),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: pathController,
                        decoration: const InputDecoration(
                          hintText: '/storage/emulated/0/...',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.folder_open),
                      onPressed: () async {
                        String? initialUri;
                        if (pathController.text.startsWith('/storage/emulated/0/')) {
                          String relPath = pathController.text.substring(20).replaceAll('/', '%2F');
                          
                          // SAF navigation to subfolders in Android/data is often restricted.
                          // Target the package root in Android/data.
                          if (pathController.text.contains('/Android/data/')) {
                            final parts = pathController.text.split('/Android/data/');
                            if (parts.length > 1) {
                              final packageName = parts[1].split('/').first;
                              relPath = 'Android%2Fdata%2F$packageName';
                            } else {
                              relPath = 'Android';
                            }
                          }
                          
                          // Use the 'tree' format for better reliability
                          initialUri = 'content://com.android.externalstorage.documents/tree/primary%3A$relPath';
                        }
                        String? picked = await ref.read(systemPathServiceProvider).openDirectoryPicker(initialUri: initialUri);
                        if (picked != null) {
                          setDialogState(() {
                            pathController.text = picked;
                          });
                        }
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
            TextButton(onPressed: () => Navigator.pop(context, pathController.text), child: const Text('Save')),
          ],
        ),
      ),
    );

    if (confirmedPath != null && confirmedPath.isNotEmpty) {
      await pathService.setSystemEmulator(systemId, selectedEmulatorId);
      await pathService.setSystemPath(systemId, confirmedPath);
      await _loadConfiguredPaths();
      ref.invalidate(systemPathsProvider);
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final isLandscape = MediaQuery.of(context).orientation == Orientation.landscape;
    
    return Scaffold(
      appBar: AppBar(
        title: const Text('Library Setup'),
        actions: [
          if (_foundSystems.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(right: 16.0),
              child: TextButton.icon(
                style: TextButton.styleFrom(
                  backgroundColor: Colors.green.withOpacity(0.8),
                  foregroundColor: Colors.white,
                ),
                onPressed: () async {
                  ref.invalidate(systemPathsProvider);
                  // Safety delay to allow persistence to settle and refresh to trigger
                  await Future.delayed(const Duration(milliseconds: 300));
                  if (mounted) context.go('/dashboard');
                },
                icon: const Icon(Icons.check_circle_outline),
                label: const Text('FINISH SETUP', style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            ),
        ],
      ),
      body: LayoutBuilder(builder: (context, constraints) {
        final content = [
          Container(
            width: isLandscape ? 320 : double.infinity,
            color: Colors.black26,
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text('SELECT ROMS ROOT',
                      style: TextStyle(
                          fontWeight: FontWeight.bold, color: Colors.blue)),
                  const SizedBox(height: 8),
                  const Text('Base folder containing your game subfolders (e.g. Roms/ps2, Roms/snes).',
                      style: TextStyle(fontSize: 13, color: Colors.grey)),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _pathController,
                    decoration: InputDecoration(
                      labelText: 'Path',
                      border: const OutlineInputBorder(),
                      isDense: true,
                      suffixIcon: IconButton(
                        icon: const Icon(Icons.folder_open),
                        onPressed: _pickGlobalFolder,
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  SizedBox(
                    height: 64,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.blue.withOpacity(0.3),
                          foregroundColor: Colors.white,
                      ),
                      onPressed: _isScanning ? null : _scan,
                      child: _isScanning
                          ? const SizedBox(height: 24, width: 24, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                          : const Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(Icons.search),
                                SizedBox(width: 12),
                                Text('SCAN LIBRARY',
                                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                              ],
                            ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          
          // RIGHT PANEL: DETECTED SYSTEMS
          Expanded(
            flex: 1,
            child: _foundSystems.isEmpty 
              ? const Center(child: Text('No systems detected yet.\nSelect your ROMs root and click "Scan".', textAlign: TextAlign.center))
              : FutureBuilder<List<EmulatorConfig>>(
                  future: ref.watch(systemsProvider.future),
                  builder: (context, snapshot) {
                    if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
                    final foundIds = _foundSystems.map((e) => e['systemId']).toList();
                    final systems = snapshot.data!.where((s) => foundIds.contains(s.system.id)).toList();
                    
                    return ListView.builder(
                      padding: const EdgeInsets.all(16),
                      itemCount: systems.length,
                      itemBuilder: (context, index) {
                        final sys = systems[index];
                        final isConfigured = _configuredPaths.containsKey(sys.system.id);
                        
                        return Card(
                          margin: const EdgeInsets.only(bottom: 8),
                          child: ListTile(
                            leading: Icon(
                              Icons.gamepad, 
                              color: isConfigured ? Colors.blue : Colors.orange
                            ),
                            title: Text(sys.system.name, style: const TextStyle(fontWeight: FontWeight.bold)),
                            subtitle: Text(isConfigured ? 'Configured' : 'Needs Setup'),
                            trailing: isConfigured 
                              ? const Icon(Icons.check_circle, color: Colors.green)
                              : const Icon(Icons.warning_amber_rounded, color: Colors.orange),
                            onTap: () => _configureSystem(sys.system.id),
                          ),
                        );
                      },
                    );
                  }
                ),
          ),
        ];

        return isLandscape 
          ? Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: content)
          : Column(children: content);
      }),
    );
  }
}
