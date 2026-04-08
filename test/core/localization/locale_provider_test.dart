import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vaultsync_client/core/localization/locale_provider.dart';
import 'package:vaultsync_client/core/services/vaultsync_launcher.dart';
import 'package:mocktail/mocktail.dart';

class MockVaultSyncLauncher extends Mock implements VaultSyncLauncher {}

void main() {
  late MockVaultSyncLauncher mockLauncher;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    mockLauncher = MockVaultSyncLauncher();
    when(() => mockLauncher.setNativeLocale(any())).thenAnswer((_) async => {});
  });

  test('defaults to English', () async {
    final container = ProviderContainer(
      overrides: [
        vaultSyncLauncherProvider.overrideWithValue(mockLauncher),
      ],
    );
    addTearDown(container.dispose);

    expect(container.read(localeProvider), const Locale('en'));
  });

  test('updates locale and persists it', () async {
    final container = ProviderContainer(
      overrides: [
        vaultSyncLauncherProvider.overrideWithValue(mockLauncher),
      ],
    );
    addTearDown(container.dispose);

    await container.read(localeProvider.notifier).setLocale(const Locale('es'));
    
    expect(container.read(localeProvider), const Locale('es'));
    
    // We expect at least one call to 'es'
    verify(() => mockLauncher.setNativeLocale('es')).called(greaterThanOrEqualTo(1));

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('selected_language'), 'es');
  });

  test('loads persisted locale', () async {
    SharedPreferences.setMockInitialValues({'selected_language': 'fr'});
    
    final container = ProviderContainer(
      overrides: [
        vaultSyncLauncherProvider.overrideWithValue(mockLauncher),
      ],
    );
    addTearDown(container.dispose);

    // Wait until the state becomes 'fr' (up to 500ms)
    bool loaded = false;
    for (int i = 0; i < 50; i++) {
      if (container.read(localeProvider) == const Locale('fr')) {
        loaded = true;
        break;
      }
      await Future.delayed(const Duration(milliseconds: 10));
    }

    expect(loaded, isTrue, reason: 'Locale should have loaded fr from preferences');
    expect(container.read(localeProvider), const Locale('fr'));
    verify(() => mockLauncher.setNativeLocale('fr')).called(greaterThanOrEqualTo(1));
  });
}
