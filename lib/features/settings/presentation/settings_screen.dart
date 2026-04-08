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
import '../../../core/services/vaultsync_launcher.dart';
import '../../../core/localization/locale_provider.dart';
import '../../auth/domain/auth_provider.dart';
import '../../sync/services/system_path_service.dart';
import '../../sync/services/background_sync_service.dart';
import '../../sync/services/desktop_background_sync_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../../l10n/generated/app_localizations.dart';

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
  String _appVersionFull = 'VaultSync v1.3.7-Secure';
  String _syncEngineDescription = 'Hardware-Accelerated Sync Engine';

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
    final launcher = ref.read(vaultSyncLauncherProvider);

    // Fetch version from strings.xml if on Android
    if (Platform.isAndroid) {
      final version = await launcher.getAppVersionFull();
      final desc = await launcher.getSyncEngineDescription();
      if (mounted) {
        setState(() {
          _appVersionFull = 'VaultSync $version';
          _syncEngineDescription = desc;
        });
      }
    }
    
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
    final locale = ref.watch(localeProvider);
    final l10n = AppLocalizations.of(context)!;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.settingsTitle)),
      body: ListView(
        children: [
          _buildSection(l10n.sectionServerAccount),
          ListTile(
            title: Text(l10n.serverUrlTitle),
            subtitle: Text(_serverUrl.isEmpty ? l10n.notSet : _serverUrl),
            leading: const Icon(Icons.cloud_queue),
            onTap: () => context.push('/setup'),
          ),
          ListTile(
            title: Text(l10n.accountTitle),
            subtitle: Text(ref.watch(authProvider)?.email ?? l10n.notLoggedIn),
            leading: const Icon(Icons.person_outline),
            trailing: TextButton(
              onPressed: () => ref.read(authProvider.notifier).logout(),
              child: Text(l10n.logoutButton, style: const TextStyle(color: Colors.red)),
            ),
          ),
          
          _buildSection(l10n.sectionAutomation),
          SwitchListTile(
            title: Text(l10n.syncOnExitTitle),
            subtitle: Text(l10n.syncOnExitSubtitle),
            value: _autoSyncOnExit,
            onChanged: _toggleAutoSync,
            secondary: const Icon(Icons.bolt),
          ),
          if (Platform.isAndroid && !_hasUsagePermission && _autoSyncOnExit)
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
                    Text(l10n.usageAccessRequired, style: const TextStyle(fontSize: 12)),
                    const SizedBox(height: 8),
                    ElevatedButton(
                      onPressed: _grantUsageStats,
                      style: ElevatedButton.styleFrom(backgroundColor: Colors.orange, foregroundColor: Colors.white),
                      child: Text(l10n.grantPermissionButton),
                    )
                  ],
                ),
              ),
            ),
          SwitchListTile(
            title: Text(l10n.periodicSyncTitle),
            subtitle: Text(l10n.periodicSyncSubtitle),
            value: _periodicSync,
            onChanged: _togglePeriodicSync,
            secondary: const Icon(Icons.timer_outlined),
          ),
          ListTile(
            title: Text(l10n.viewSyncHistoryTitle),
            subtitle: Text(l10n.viewSyncHistorySubtitle),
            leading: const Icon(Icons.history),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/history'),
          ),
          ListTile(
            title: Text(l10n.conflictStrategyTitle),
            subtitle: Text(l10n.conflictStrategySubtitle),
            leading: const Icon(Icons.compare_outlined),
            trailing: DropdownButton<String>(
              value: _conflictStrategy,
              onChanged: _setConflictStrategy,
              items: [
                DropdownMenuItem(value: 'ask', child: Text(l10n.strategyAsk)),
                DropdownMenuItem(value: 'newest', child: Text(l10n.strategyNewest)),
                DropdownMenuItem(value: 'local', child: Text(l10n.strategyLocal)),
                DropdownMenuItem(value: 'cloud', child: Text(l10n.strategyCloud)),
              ],
            ),
          ),

          _buildSection(l10n.sectionHardwareBridge),
          if (Platform.isAndroid)
            SwitchListTile(
              title: Text(l10n.useShizukuTitle),
              subtitle: Text(l10n.useShizukuSubtitle),
              value: _useShizuku,
              onChanged: _toggleShizuku,
              secondary: const Icon(Icons.shield_outlined),
            ),
          ListTile(
            title: Text(l10n.runDiagnosticsTitle),
            subtitle: Text(l10n.runDiagnosticsSubtitle),
            leading: const Icon(Icons.speed),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/diagnostics'),
          ),

          if (Platform.isLinux) ..._buildDeckyBridgeSection(l10n),

          _buildSection(l10n.sectionAppearance),
          ListTile(
            title: Text(l10n.themeModeTitle),
            leading: const Icon(Icons.palette_outlined),
            trailing: DropdownButton<ThemeMode>(
              value: themeMode,
              onChanged: (mode) => ref.read(themeProvider.notifier).setTheme(mode!),
              items: [
                DropdownMenuItem(value: ThemeMode.system, child: Text(l10n.themeSystem)),
                DropdownMenuItem(value: ThemeMode.light, child: Text(l10n.themeLight)),
                DropdownMenuItem(value: ThemeMode.dark, child: Text(l10n.themeDark)),
              ],
            ),
          ),

          _buildSection(l10n.sectionLanguage),
          ListTile(
            title: Text(l10n.languageTitle),
            leading: const Icon(Icons.language),
            trailing: DropdownButton<String>(
              value: locale.languageCode,
              onChanged: (lang) {
                if (lang != null) {
                  ref.read(localeProvider.notifier).setLocale(Locale(lang));
                }
              },
              items: const [
                DropdownMenuItem(value: 'en', child: Text('English')),
                DropdownMenuItem(value: 'es', child: Text('Español')),
                DropdownMenuItem(value: 'fr', child: Text('Français')),
                DropdownMenuItem(value: 'de', child: Text('Deutsch')),
                DropdownMenuItem(value: 'it', child: Text('Italiano')),
              ],
            ),
          ),
          
          const Divider(),
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Text('$_appVersionFull\n$_syncEngineDescription', textAlign: TextAlign.center, style: const TextStyle(color: Colors.grey, fontSize: 12)),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildDeckyBridgeSection(AppLocalizations l10n) {
    final installerAsync = ref.watch(deckyServiceInstallerProvider);
    final status = installerAsync.valueOrNull ?? DeckyBridgeStatus.unknown;

    final statusText = switch (status) {
      DeckyBridgeStatus.running => l10n.statusRunning,
      DeckyBridgeStatus.stopped => l10n.statusStopped,
      DeckyBridgeStatus.installing => l10n.statusInstalling,
      DeckyBridgeStatus.notInstalled => l10n.statusNotInstalled,
      DeckyBridgeStatus.unknown => l10n.statusChecking,
    };

    final statusColor = switch (status) {
      DeckyBridgeStatus.running => Colors.green,
      DeckyBridgeStatus.stopped => Colors.orange,
      DeckyBridgeStatus.installing => Colors.blue,
      DeckyBridgeStatus.notInstalled => Colors.grey,
      DeckyBridgeStatus.unknown => Colors.grey,
    };

    return [
      _buildSection(l10n.sectionDeckyBridge),
      ListTile(
        leading: Icon(Icons.gamepad_outlined, color: statusColor),
        title: Text(l10n.bridgeServiceTitle),
        subtitle: Text(l10n.bridgeServiceSubtitle(statusText)),
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
                  label: Text(l10n.installEnableButton),
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
                  label: Text(l10n.startButton),
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
                child: Text(l10n.uninstallButton),
              ),
            ],
            if (status == DeckyBridgeStatus.running) ...[
              OutlinedButton.icon(
                icon: const Icon(Icons.stop),
                label: Text(l10n.stopButton),
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
