import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vaultsync_client/features/sync/presentation/sync_history_screen.dart';
import 'package:vaultsync_client/l10n/generated/app_localizations.dart';

Map<String, dynamic> _logJson({
  required String systemId,
  required String status,
  String? errorTitle,
  String? detail,
}) =>
    {
      'systemId': systemId,
      'status': status,
      'timestamp': DateTime(2026, 1, 1, 12).toIso8601String(),
      'isError': true,
      'errorTitle': errorTitle,
      'actionLabel': null,
      'detail': detail,
    };

Future<void> _pumpHistoryScreen(WidgetTester tester) async {
  await tester.pumpWidget(
    const ProviderScope(
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: Locale('en'),
        home: SyncHistoryScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    // Reset mocked SharedPreferences between tests so history from one test
    // doesn't leak into the next.
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('shows the technical detail as a secondary line under the entry', (tester) async {
    SharedPreferences.setMockInitialValues({
      'sync_history_logs': [
        jsonEncode(_logJson(
          systemId: 'dc',
          status: 'An unexpected error occurred. Please try again.',
          errorTitle: 'Sync Failed',
          detail: 'FileSystemException: Cannot open file (OS Error: No such file or directory)',
        )),
      ],
    });

    await _pumpHistoryScreen(tester);

    expect(find.textContaining('FileSystemException'), findsOneWidget);
  });

  testWidgets('tapping the detail line opens a dialog with the full text', (tester) async {
    SharedPreferences.setMockInitialValues({
      'sync_history_logs': [
        jsonEncode(_logJson(
          systemId: 'dc',
          status: 'An unexpected error occurred. Please try again.',
          errorTitle: 'Sync Failed',
          detail: 'FileSystemException: Cannot open file (OS Error: No such file or directory)',
        )),
      ],
    });

    await _pumpHistoryScreen(tester);

    await tester.tap(find.textContaining('FileSystemException'));
    await tester.pumpAndSettle();

    expect(find.byType(SelectableText), findsOneWidget);
    expect(find.textContaining('Cause: FileSystemException'), findsOneWidget);
  });

  testWidgets('does not overflow when the detail is very long', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    final longDetail = List.filled(
      10,
      'FileSystemException: Cannot open file, path = '
          '/storage/emulated/0/Android/data/com.flycast.emulator/files/saves/'
          'really/long/nested/path/save.bin (OS Error: No such file or directory, errno = 2)',
    ).join(' ');

    SharedPreferences.setMockInitialValues({
      'sync_history_logs': [
        jsonEncode(_logJson(
          systemId: 'dc',
          status: 'An unexpected error occurred. Please try again.',
          errorTitle: 'Sync Failed',
          detail: longDetail,
        )),
      ],
    });

    await _pumpHistoryScreen(tester);

    expect(tester.takeException(), isNull);
  });

  testWidgets('entries with no detail (pre-existing history) render with no secondary line',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      'sync_history_logs': [
        jsonEncode(_logJson(
          systemId: 'psp',
          status: 'Synced successfully',
        )),
      ],
    });

    await _pumpHistoryScreen(tester);

    expect(find.text('PSP'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
