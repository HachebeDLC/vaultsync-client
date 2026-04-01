import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:vaultsync_client/core/utils/offline_banner.dart';
import 'package:vaultsync_client/core/services/connectivity_provider.dart';

void main() {
  testWidgets('OfflineBanner should show text when offline', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          isOnlineProvider.overrideWith((ref) => false),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: Stack(
              children: [
                OfflineBanner(),
              ],
            ),
          ),
        ),
      ),
    );

    expect(find.text('Device is offline. Changes will be queued.'), findsOneWidget);
    expect(find.byIcon(Icons.wifi_off), findsOneWidget);
  });

  testWidgets('OfflineBanner should be empty when online', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          isOnlineProvider.overrideWith((ref) => true),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: OfflineBanner(),
          ),
        ),
      ),
    );

    expect(find.text('Device is offline. Changes will be queued.'), findsNothing);
  });
}
