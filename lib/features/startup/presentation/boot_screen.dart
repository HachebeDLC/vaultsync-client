import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/services/api_client_provider.dart';
import '../../auth/domain/auth_provider.dart';
import '../../sync/services/system_path_service.dart';
import '../../sync/services/desktop_tray_service.dart';

import 'package:shared_preferences/shared_preferences.dart';
import '../../sync/services/background_sync_service.dart';

class BootScreen extends ConsumerStatefulWidget {
  const BootScreen({super.key});

  @override
  ConsumerState<BootScreen> createState() => _BootScreenState();
}

class _BootScreenState extends ConsumerState<BootScreen> {
  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    final client = ref.read(apiClientProvider);
    
    // Initialize Desktop Tray if applicable
    if (Platform.isWindows || Platform.isLinux) {
      await ref.read(desktopTrayServiceProvider).initTray();
    }
    
    // Add a small artificial delay so the user can actually see the loading screen
    await Future.delayed(const Duration(milliseconds: 800));

    try {
      final baseUrl = await client.getBaseUrl();
      if (baseUrl == null || baseUrl.isEmpty) {
        context.go('/setup');
        return;
      }

      print('🌐 BOOT: Checking connectivity to $baseUrl');
      
      // Attempt Auth initialization
      await ref.read(authProvider.notifier).init();
      
      if (!mounted) return;

      if (ref.read(authProvider.notifier).isAuthenticated) {
        final paths = await ref.read(systemPathServiceProvider).getAllSystemPaths();
        if (!mounted) return;
        
        if (paths.isEmpty) {
          context.go('/library-setup');
        } else {
          context.go('/dashboard');
        }
      } else {
        context.go('/auth');
      }
    } on SocketException catch (e) {
      print('🌐 BOOT: Network unreachable ($e). Likely device lock or no signal.');
      if (mounted) context.go('/auth');
    } on FormatException catch (e) {
      print('❌ BOOT: Malformed server response ($e). URL configuration might be invalid.');
      if (mounted) context.go('/setup');
    } catch (e) {
      print('❌ BOOT: Unexpected error during startup: $e');
      if (mounted) context.go('/auth');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 20),
            Text(
              'Initializing VaultSync...',
              style: Theme.of(context).textTheme.titleLarge,
            ),
          ],
        ),
      ),
    );
  }
}
