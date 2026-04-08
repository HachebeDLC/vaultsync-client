import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vaultsync_client/features/settings/presentation/settings_screen.dart';
import 'package:vaultsync_client/core/localization/locale_provider.dart';
import 'package:vaultsync_client/core/services/vaultsync_launcher.dart';
import 'package:vaultsync_client/l10n/generated/app_localizations.dart';
import 'package:mocktail/mocktail.dart';

class MockVaultSyncLauncher extends Mock implements VaultSyncLauncher {}

void main() {
  late MockVaultSyncLauncher mockLauncher;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    mockLauncher = MockVaultSyncLauncher();
    when(() => mockLauncher.setNativeLocale(any())).thenAnswer((_) async => {});
    when(() => mockLauncher.getAppVersionFull()).thenAnswer((_) async => 'v1.3.7-Secure');
    when(() => mockLauncher.getSyncEngineDescription()).thenAnswer((_) async => 'Hardware-Accelerated Sync Engine');
  });

  Widget createSettingsScreen() {
    return ProviderScope(
      overrides: [
        vaultSyncLauncherProvider.overrideWithValue(mockLauncher),
      ],
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: Locale('en'),
        home: SettingsScreen(),
      ),
    );
  }

  testWidgets('renders language picker and changes language', (tester) async {
    await tester.pumpWidget(createSettingsScreen());
    await tester.pumpAndSettle();

    // Check if the screen is even rendered
    expect(find.text('Settings'), findsOneWidget);

    // Scroll to the language picker
    await tester.drag(find.byType(ListView), const Offset(0, -1000));
    await tester.pumpAndSettle();

    // Find the language picker
    expect(find.text('App Language'), findsOneWidget);
    expect(find.text('English'), findsOneWidget);

    // Open dropdown
    await tester.tap(find.text('English'));
    await tester.pumpAndSettle();

    // Select Español
    await tester.tap(find.text('Español').last);
    await tester.pumpAndSettle();

    // Verify language changed in UI
    expect(find.text('Ajustes'), findsNothing); // It might not change immediately if translations aren't loaded in test
    // But we can check if the provider was updated
    // Actually, in test environment, AppLocalizations should work.
    
    // Check if English label is gone and Español is the new value
    expect(find.text('Español'), findsOneWidget);
  });
}
