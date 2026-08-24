import 'dart:developer' as developer;
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/services/api_client_provider.dart';
import '../../auth/domain/auth_provider.dart';
import '../../sync/services/system_path_service.dart';
import '../../sync/services/desktop_tray_service.dart';


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
    
    try {
      final baseUrl = await client.getBaseUrl();
      if (baseUrl == null || baseUrl.isEmpty) {
        context.go('/setup');
        return;
      }

      developer.log('BOOT: Checking connectivity to $baseUrl', name: 'VaultSync', level: 800);
      
      // Attempt Auth initialization
      await ref.read(authProvider.notifier).init();
      
      if (!mounted) return;

      if (ref.read(authProvider.notifier).isAuthenticated) {
        // A token can outlive the master key. Reinstalling the APK leaves the
        // auth token readable but drops the key from secure storage, and the
        // app carried on as if nothing had happened: uploads silently went up
        // as plaintext and downloads were written as raw ciphertext. On one
        // device that produced PS2 memory cards 39 bytes too long — magic, IV
        // and padding — which the emulator reported as damaged saves.
        //
        // The key is derived from the password, so the only way back is a
        // fresh login. Do it here rather than let sync discover it later.
        if (await client.getEncryptionKey() == null) {
          developer.log(
              'BOOT: Session has a token but no master key — signing out so it can be re-derived',
              name: 'VaultSync',
              level: 1000);
          await client.clearToken();
          if (mounted) context.go('/auth');
          return;
        }

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
      developer.log('BOOT: Network unreachable. Likely device lock or no signal.', name: 'VaultSync', level: 900, error: e);
      if (mounted) context.go('/auth');
    } on FormatException catch (e) {
      developer.log('BOOT: Malformed server response. URL configuration might be invalid.', name: 'VaultSync', level: 1000, error: e);
      if (mounted) context.go('/setup');
    } catch (e) {
      developer.log('BOOT: Unexpected error during startup', name: 'VaultSync', level: 1000, error: e);
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
