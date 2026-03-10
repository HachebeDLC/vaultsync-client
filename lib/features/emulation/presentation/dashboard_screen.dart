import 'package:flutter/material.dart';
import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../../sync/domain/sync_provider.dart';
import '../../sync/services/system_path_service.dart';
import '../../sync/services/shizuku_service.dart';
import '../../../core/utils/responsive_layout.dart';

class DashboardScreen extends ConsumerStatefulWidget {
  const DashboardScreen({super.key});

  @override
  ConsumerState<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends ConsumerState<DashboardScreen> {
  int _navIndex = 0;
  ShizukuStatus? _shizukuStatus;

  @override
  void initState() {
    super.initState();
    // Proactively refresh conflicts when dashboard loads
    Future.microtask(() => ref.read(syncProvider.notifier).refreshConflicts());
    
    if (Platform.isAndroid) {
      _checkShizukuStatus();
    }
  }

  Future<void> _checkShizukuStatus() async {
    final status = await ref.read(shizukuServiceProvider).getStatus();
    if (mounted) {
      setState(() => _shizukuStatus = status);
    }
  }

  String _formatSafPath(String path) {
    if (path.startsWith('content://')) {
      try {
        final decoded = Uri.decodeComponent(path);
        if (decoded.contains('primary:')) {
          return '/storage/emulated/0/${decoded.split('primary:').last}';
        } else if (decoded.contains(':')) {
          final parts = decoded.split(':');
          return 'SD Card/${parts.last.split('/document/').last}';
        }
        return decoded.split('/').last;
      } catch (_) {}
    }
    return path;
  }

  Widget _getSystemIconWidget(String systemId, {double size = 24}) {
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

    return SvgPicture.asset(
      'assets/systems/$iconName.svg',
      width: size,
      height: size,
      colorFilter: const ColorFilter.mode(Colors.blue, BlendMode.srcIn),
      placeholderBuilder: (context) => Icon(_getFallbackIcon(id), size: size, color: Colors.blue),
      errorBuilder: (context, error, stackTrace) => Icon(_getFallbackIcon(id), size: size, color: Colors.blue),
    );
  }

  Widget _buildShizukuBanner() {
    final isNotRunning = !_shizukuStatus!.isRunning;
    
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.orange.withOpacity(0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.orange.withOpacity(0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.shield_outlined, color: Colors.orange, size: 20),
              const SizedBox(width: 8),
              Text(
                isNotRunning ? 'Shizuku Recommended' : 'Shizuku Authorization Needed',
                style: const TextStyle(color: Colors.orange, fontWeight: FontWeight.bold)
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            isNotRunning 
              ? 'Shizuku is not running. On Android 13+, Shizuku is required for high-performance access to restricted folders.'
              : 'Shizuku is running but VaultSync does not have permission to use it.',
            style: const TextStyle(fontSize: 12),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => setState(() => _shizukuStatus = null),
                child: const Text('DISMISS'),
              ),
              const SizedBox(width: 8),
              ElevatedButton(
                onPressed: () async {
                  if (isNotRunning) {
                    _checkShizukuStatus();
                  } else {
                    final granted = await ref.read(shizukuServiceProvider).requestPermission();
                    if (granted) _checkShizukuStatus();
                  }
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.orange,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                ),
                child: Text(isNotRunning ? 'RETRY' : 'GRANT PERMISSION'),
              ),
            ],
          ),
        ],
      ),
    );
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
    final pathsAsync = ref.watch(systemPathsProvider);
    final isDesktop = ResponsiveLayout.isDesktop(context);
    final isTablet = ResponsiveLayout.isTablet(context);
    final showNavRail = isDesktop || isTablet;

    Widget mainContent = Column(
        children: [
          if (syncState.syncErrors.isNotEmpty)
            Container(
              color: Colors.red.shade900,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  const Icon(Icons.error_outline, color: Colors.white),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      '${syncState.syncErrors.length} sync errors detected',
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                    ),
                  ),
                  TextButton(
                    onPressed: () => ref.read(syncProvider.notifier).clearErrors(),
                    child: const Text('DISMISS', style: TextStyle(color: Colors.white, decoration: TextDecoration.underline)),
                  ),
                ],
              ),
            ),
          
          if (_shizukuStatus != null && (!_shizukuStatus!.isRunning || !_shizukuStatus!.isAuthorized))
            _buildShizukuBanner(),

          Expanded(
            child: pathsAsync.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (err, stack) => Center(child: Text('Error: $err')),
              data: (paths) {
                print('🎨 RENDER: Dashboard building with ${paths.length} systems');
                
                if (paths.isEmpty) {
                  return Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.folder_open, size: 64, color: Colors.grey),
                        const SizedBox(height: 16),
                        const Text('No systems configured yet.'),
                        const SizedBox(height: 24),
                        ElevatedButton.icon(
                          icon: const Icon(Icons.search),
                          label: const Text('Scan Library'),
                          onPressed: () => context.push('/library-setup'),
                        ),
                      ],
                    ),
                  );
                }

                return LayoutBuilder(builder: (context, constraints) {
                  final isWide = constraints.maxWidth > 800;
                  
                  final systemsListView = ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: paths.length,
                    itemBuilder: (context, index) {
                      final entry = paths.entries.elementAt(index);
                      final systemId = entry.key;
                      return Card(
                        margin: const EdgeInsets.only(bottom: 8),
                        child: InkWell(
                          onTap: () => context.push('/system-detail/$systemId'),
                          mouseCursor: SystemMouseCursors.click,
                          child: Tooltip(
                            message: 'Manage $systemId saves',
                            child: ListTile(
                              leading: CircleAvatar(
                                backgroundColor: Colors.blue.withOpacity(0.1),
                                child: _getSystemIconWidget(systemId),
                              ),
                              title: Text(systemId.toUpperCase(), style: const TextStyle(fontWeight: FontWeight.bold)),
                              subtitle: Text(_formatSafPath(entry.value), maxLines: 1, overflow: TextOverflow.ellipsis),
                              trailing: const Icon(Icons.check_circle, color: Colors.green, size: 20),
                            ),
                          ),
                        ),
                      );
                    },
                  );

                  final statusCard = Card(
                      elevation: 4,
                      margin: const EdgeInsets.all(16),
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              syncState.isSyncing ? Icons.sync : Icons.cloud_done,
                              size: 64,
                              color: syncState.isSyncing ? Colors.blue : Colors.green,
                            ),
                            const SizedBox(height: 16),
                            Text(
                              syncState.isSyncing ? 'Syncing...' : 'System Ready',
                              style: Theme.of(context).textTheme.headlineSmall,
                            ),
                            const SizedBox(height: 24),
                            if (syncState.isSyncing) ...[
                              Stack(
                                alignment: Alignment.center,
                                children: [
                                  SizedBox(
                                    height: 24,
                                    child: ClipRRect(
                                      borderRadius: BorderRadius.circular(12),
                                      child: LinearProgressIndicator(
                                        value: syncState.progress > 0 ? syncState.progress : null,
                                        minHeight: 24,
                                      ),
                                    ),
                                  ),
                                  Text(
                                    syncState.status,
                                    style: const TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.white,
                                      shadows: [Shadow(blurRadius: 2, color: Colors.black54)],
                                    ),
                                    textAlign: TextAlign.center,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                              ),
                              const SizedBox(height: 24),
                              OutlinedButton.icon(
                                icon: const Icon(Icons.stop, color: Colors.red),
                                label: const Text('STOP SYNC', style: TextStyle(color: Colors.red)),
                                style: OutlinedButton.styleFrom(
                                  minimumSize: const Size(double.infinity, 50),
                                  side: const BorderSide(color: Colors.red),
                                ),
                                onPressed: () => ref.read(syncProvider.notifier).cancelSync(),
                              ),
                            ] else ...[
                              Text(syncState.status.isEmpty ? 'Waiting for changes' : syncState.status),
                              const SizedBox(height: 24),
                              ElevatedButton.icon(
                                icon: const Icon(Icons.sync),
                                label: const Text('Sync All Systems'),
                                style: ElevatedButton.styleFrom(minimumSize: const Size(double.infinity, 54)),
                                onPressed: () => ref.read(syncProvider.notifier).sync(),
                              ),
                            ],
                            if (!syncState.isSyncing && syncState.conflicts.isNotEmpty) ...[
                              const SizedBox(height: 12),
                              OutlinedButton.icon(
                                icon: const Icon(Icons.warning_amber_rounded, color: Colors.orange),
                                label: Text('RESOLVE ${syncState.conflicts.length} CONFLICTS', style: const TextStyle(color: Colors.orange)),
                                style: OutlinedButton.styleFrom(
                                  minimumSize: const Size(double.infinity, 54),
                                  side: const BorderSide(color: Colors.orange),
                                ),
                                onPressed: () => context.push('/conflicts'),
                              ),
                            ],
                          ],
                        ),
                      ),
                    );

                  if (isWide) {
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(flex: 4, child: statusCard),
                        const VerticalDivider(width: 1),
                        Expanded(flex: 6, child: systemsListView),
                      ],
                    );
                  } else {
                    return Column(
                      children: [
                        ConstrainedBox(
                          constraints: BoxConstraints(maxHeight: constraints.maxHeight * 0.4),
                          child: statusCard,
                        ),
                        const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 16.0),
                          child: Divider(),
                        ),
                        Expanded(child: systemsListView),
                      ],
                    );
                  }
                });
              },
            ),
          ),
        ],
      );

    if (showNavRail) {
      return Scaffold(
        body: Row(
          children: [
            NavigationRail(
              extended: isDesktop,
              selectedIndex: _navIndex,
              onDestinationSelected: (index) {
                setState(() => _navIndex = index);
                if (index == 1) context.push('/library-setup');
                if (index == 2) context.push('/settings');
              },
              leading: const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Icon(Icons.lock_person, color: Colors.blue, size: 32),
              ),
              destinations: const [
                NavigationRailDestination(
                  icon: Icon(Icons.dashboard_outlined),
                  selectedIcon: Icon(Icons.dashboard),
                  label: Text('Dashboard'),
                ),
                NavigationRailDestination(
                  icon: Icon(Icons.search),
                  label: Text('Scan Library'),
                ),
                NavigationRailDestination(
                  icon: Icon(Icons.settings_outlined),
                  selectedIcon: Icon(Icons.settings),
                  label: Text('Settings'),
                ),
              ],
            ),
            const VerticalDivider(thickness: 1, width: 1),
            Expanded(child: mainContent),
          ],
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('VaultSync Dashboard'),
        actions: [
          IconButton(
            tooltip: 'Scan Library',
            icon: const Icon(Icons.search),
            onPressed: () => context.push('/library-setup'),
          ),
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings),
            onPressed: () => context.push('/settings'),
          ),
        ],
      ),
      body: mainContent,
    );
  }
}
