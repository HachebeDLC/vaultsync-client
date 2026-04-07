import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter/services.dart';
import 'dart:developer' as developer;
import 'dart:io';
import 'package:workmanager/workmanager.dart';
import '../../../core/theme/theme_provider.dart';
import '../../../core/services/api_client_provider.dart';
import '../../../core/services/decky_service_installer.dart';
import '../../auth/domain/auth_provider.dart';
import '../../sync/services/system_path_service.dart';
import '../../sync/services/background_sync_service.dart';
import '../../sync/services/desktop_background_sync_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> with WidgetsBindingObserver {
  static const _platform = MethodChannel('com.vaultsync.app/launcher');
  bool _useShizuku = false;
  bool _autoSyncOnExit = false;
  bool _periodicSync = false;
  bool _hasUsagePermission = false;
  String _serverUrl = '';
  String _conflictStrategy = 'ask';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadSettings();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _loadSettings();
    }
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final apiClient = ref.read(apiClientProvider);
    final url = await apiClient.getBaseUrl() ?? '';
    
    bool usage = false;
    if (Platform.isAndroid) {
      try {
        usage = await _platform.invokeMethod<bool>('hasUsageStatsPermission') ?? false;
      } catch (e) { developer.log('Settings: checkShizukuStatus failed', name: 'VaultSync', level: 900, error: e); }
    }

    if (mounted) {
      setState(() {
        _useShizuku = prefs.getBool('use_shizuku') ?? false;
        _autoSyncOnExit = prefs.getBool('auto_sync_on_exit') ?? false;
        _periodicSync = prefs.getBool('periodic_sync') ?? false;
        _serverUrl = url;
        _hasUsagePermission = usage;
        _conflictStrategy = prefs.getString('conflict_strategy') ?? 'ask';
      });
    }
  }

  Future<void> _setConflictStrategy(String? strategy) async {
    if (strategy == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('conflict_strategy', strategy);
    setState(() => _conflictStrategy = strategy);
  }

  Future<void> _toggleShizuku(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('use_shizuku', value);
    setState(() => _useShizuku = value);
    ref.invalidate(systemPathsProvider);
  }

  Future<void> _toggleAutoSync(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('auto_sync_on_exit', value);
    setState(() => _autoSyncOnExit = value);
    
    if (value) {
       if (_hasUsagePermission) {
          ref.read(backgroundSyncServiceProvider).startMonitoring();
       }
    } else {
       ref.read(backgroundSyncServiceProvider).stopMonitoring();
    }
  }

  Future<void> _togglePeriodicSync(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('periodic_sync', value);
    setState(() => _periodicSync = value);

    if (Platform.isAndroid || Platform.isIOS) {
      if (value) {
        developer.log('SCHEDULER: Registering periodic sync (6 hours)', name: 'VaultSync', level: 800);
        await Workmanager().registerPeriodicTask(
          "periodic-sync",
          "syncTask",
          frequency: const Duration(hours: 6),
          constraints: Constraints(
            networkType: NetworkType.connected,
            requiresBatteryNotLow: true,
          ),
        );
      } else {
        developer.log('SCHEDULER: Cancelling periodic sync', name: 'VaultSync', level: 800);
        await Workmanager().cancelByUniqueName("periodic-sync");
      }
    } else if (Platform.isWindows || Platform.isLinux) {
      if (value) {
        ref.read(desktopBackgroundSyncServiceProvider).startAutoSync(interval: const Duration(hours: 6));
      } else {
        ref.read(desktopBackgroundSyncServiceProvider).stopAutoSync();
      }
    } else {
      developer.log('SCHEDULER: Background sync is not supported on this platform', name: 'VaultSync', level: 800);
    }
  }
  Future<void> _grantUsageStats() async {
    if (Platform.isAndroid) {
      await _platform.invokeMethod('openUsageStatsSettings');
    }
  }

  @override
  Widget build(BuildContext context) {
    final themeMode = ref.watch(themeProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          _buildSection('Server & Account'),
          ListTile(
            title: const Text('Server URL'),
            subtitle: Text(_serverUrl.isEmpty ? 'Not set' : _serverUrl),
            leading: const Icon(Icons.cloud_queue),
            onTap: () => context.push('/setup'),
          ),
          ListTile(
            title: const Text('Account'),
            subtitle: Text(ref.watch(authProvider)?.email ?? 'Not logged in'),
            leading: const Icon(Icons.person_outline),
            trailing: TextButton(
              onPressed: () => ref.read(authProvider.notifier).logout(),
              child: const Text('LOGOUT', style: TextStyle(color: Colors.red)),
            ),
          ),
          
          _buildSection('Automation (Beta)'),
          SwitchListTile(
            title: const Text('Sync on Game Exit'),
            subtitle: const Text('Upload saves automatically when you finish playing'),
            value: _autoSyncOnExit,
            onChanged: _toggleAutoSync,
            secondary: const Icon(Icons.bolt),
          ),
          if (!_hasUsagePermission && _autoSyncOnExit)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.orange.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.orange)
                ),
                child: Column(
                  children: [
                    const Text('Usage Access is required to detect when emulators close.', style: TextStyle(fontSize: 12)),
                    const SizedBox(height: 8),
                    ElevatedButton(
                      onPressed: _grantUsageStats,
                      style: ElevatedButton.styleFrom(backgroundColor: Colors.orange, foregroundColor: Colors.white),
                      child: const Text('GRANT PERMISSION'),
                    )
                  ],
                ),
              ),
            ),
          SwitchListTile(
            title: const Text('Periodic Background Sync'),
            subtitle: const Text('Perform a catch-up sync every 6 hours'),
            value: _periodicSync,
            onChanged: _togglePeriodicSync,
            secondary: const Icon(Icons.timer_outlined),
          ),
          ListTile(
            title: const Text('View Sync History'),
            subtitle: const Text('Review logs of background sync events'),
            leading: const Icon(Icons.history),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/history'),
          ),
          ListTile(
            title: const Text('Conflict Strategy'),
            subtitle: const Text('Choose how to resolve save discrepancies'),
            leading: const Icon(Icons.compare_outlined),
            trailing: DropdownButton<String>(
              value: _conflictStrategy,
              onChanged: _setConflictStrategy,
              items: const [
                DropdownMenuItem(value: 'ask', child: Text('Ask Every Time')),
                DropdownMenuItem(value: 'newest', child: Text('Always Newest')),
                DropdownMenuItem(value: 'local', child: Text('Prefer Local')),
                DropdownMenuItem(value: 'cloud', child: Text('Prefer Cloud')),
              ],
            ),
          ),

          _buildSection('Hardware Bridge'),
          if (Platform.isAndroid)
            SwitchListTile(
              title: const Text('Use Shizuku Bridge'),
              subtitle: const Text('High-speed access for Android 14+ /data folders'),
              value: _useShizuku,
              onChanged: _toggleShizuku,
              secondary: const Icon(Icons.shield_outlined),
            ),
          ListTile(
            title: const Text('Run System Diagnostics'),
            subtitle: const Text('Test hardware speed and SAF/Shizuku health'),
            leading: const Icon(Icons.speed),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/diagnostics'),
          ),

          if (Platform.isLinux) ..._buildDeckyBridgeSection(),

          _buildSection('Appearance'),
          ListTile(
            title: const Text('Theme Mode'),
            leading: const Icon(Icons.palette_outlined),
            trailing: DropdownButton<ThemeMode>(
              value: themeMode,
              onChanged: (mode) => ref.read(themeProvider.notifier).setTheme(mode!),
              items: const [
                DropdownMenuItem(value: ThemeMode.system, child: Text('System')),
                DropdownMenuItem(value: ThemeMode.light, child: Text('Light')),
                DropdownMenuItem(value: ThemeMode.dark, child: Text('Dark')),
              ],
            ),
          ),
          
          const Divider(),
          const Padding(
            padding: EdgeInsets.all(16.0),
            child: Text('VaultSync v1.2-Secure\nHardware-Accelerated Sync Engine', textAlign: TextAlign.center, style: TextStyle(color: Colors.grey, fontSize: 12)),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildDeckyBridgeSection() {
    final installerAsync = ref.watch(deckyServiceInstallerProvider);
    final status = installerAsync.valueOrNull ?? DeckyBridgeStatus.unknown;

    final (statusText, statusColor) = switch (status) {
      DeckyBridgeStatus.running => ('Running', Colors.green),
      DeckyBridgeStatus.stopped => ('Stopped', Colors.orange),
      DeckyBridgeStatus.installing => ('Installing...', Colors.blue),
      DeckyBridgeStatus.notInstalled => ('Not installed', Colors.grey),
      DeckyBridgeStatus.unknown => ('Checking...', Colors.grey),
    };

    return [
      _buildSection('Decky Plugin Bridge'),
      ListTile(
        leading: Icon(Icons.gamepad_outlined, color: statusColor),
        title: const Text('Bridge Service'),
        subtitle: Text(
          'Serves localhost:5437 for the Decky plugin in Game Mode\nStatus: $statusText',
        ),
        trailing: status == DeckyBridgeStatus.installing
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Icon(Icons.circle, size: 12, color: statusColor),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: Row(
          children: [
            if (status == DeckyBridgeStatus.notInstalled)
              Expanded(
                child: FilledButton.icon(
                  icon: const Icon(Icons.download_outlined),
                  label: const Text('Install & Enable'),
                  onPressed: () async {
                    final error = await ref
                        .read(deckyServiceInstallerProvider.notifier)
                        .install();
                    if (error != null && mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(error),
                          backgroundColor: Colors.red,
                          duration: const Duration(seconds: 6),
                        ),
                      );
                    }
                  },
                ),
              ),
            if (status == DeckyBridgeStatus.stopped) ...[
              Expanded(
                child: FilledButton.icon(
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Start'),
                  onPressed: () =>
                      ref.read(deckyServiceInstallerProvider.notifier).start(),
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: () async {
                  final err = await ref
                      .read(deckyServiceInstallerProvider.notifier)
                      .uninstall();
                  if (err != null && mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text(err)));
                  }
                },
                child: const Text('Uninstall'),
              ),
            ],
            if (status == DeckyBridgeStatus.running) ...[
              OutlinedButton.icon(
                icon: const Icon(Icons.stop),
                label: const Text('Stop'),
                onPressed: () =>
                    ref.read(deckyServiceInstallerProvider.notifier).stop(),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: () =>
                    ref.read(deckyServiceInstallerProvider.notifier).refresh(),
                child: const Icon(Icons.refresh),
              ),
            ],
          ],
        ),
      ),
      const SizedBox(height: 8),
    ];
  }

  Widget _buildSection(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
      child: Text(title.toUpperCase(), style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.blue)),
    );
  }
}
