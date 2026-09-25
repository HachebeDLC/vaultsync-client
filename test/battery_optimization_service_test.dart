import 'package:flutter_test/flutter_test.dart';
import 'package:vaultsync_client/features/settings/services/battery_optimization_service.dart';

void main() {
  group('BatteryOptimizationService.ensureExempt', () {
    test('does nothing when not Android', () async {
      var isIgnoringCalls = 0;
      var confirmCalls = 0;
      var requestCalls = 0;

      final service = BatteryOptimizationService(
        isAndroidOverride: false,
        isIgnoringBatteryOptimizationsOverride: () async {
          isIgnoringCalls++;
          return false;
        },
        requestIgnoreBatteryOptimizationsOverride: () async {
          requestCalls++;
          return true;
        },
      );

      await service.ensureExempt(confirm: () async {
        confirmCalls++;
        return true;
      });

      expect(isIgnoringCalls, 0);
      expect(confirmCalls, 0);
      expect(requestCalls, 0);
    });

    test('does not confirm or request when already exempt', () async {
      var confirmCalls = 0;
      var requestCalls = 0;

      final service = BatteryOptimizationService(
        isAndroidOverride: true,
        isIgnoringBatteryOptimizationsOverride: () async => true,
        requestIgnoreBatteryOptimizationsOverride: () async {
          requestCalls++;
          return true;
        },
      );

      await service.ensureExempt(confirm: () async {
        confirmCalls++;
        return true;
      });

      expect(confirmCalls, 0);
      expect(requestCalls, 0);
    });

    test('confirms but does not request when the user declines', () async {
      var confirmCalls = 0;
      var requestCalls = 0;

      final service = BatteryOptimizationService(
        isAndroidOverride: true,
        isIgnoringBatteryOptimizationsOverride: () async => false,
        requestIgnoreBatteryOptimizationsOverride: () async {
          requestCalls++;
          return true;
        },
      );

      await service.ensureExempt(confirm: () async {
        confirmCalls++;
        return false;
      });

      expect(confirmCalls, 1);
      expect(requestCalls, 0);
    });

    test('confirms and requests when not exempt and the user accepts',
        () async {
      var confirmCalls = 0;
      var requestCalls = 0;

      final service = BatteryOptimizationService(
        isAndroidOverride: true,
        isIgnoringBatteryOptimizationsOverride: () async => false,
        requestIgnoreBatteryOptimizationsOverride: () async {
          requestCalls++;
          return true;
        },
      );

      await service.ensureExempt(confirm: () async {
        confirmCalls++;
        return true;
      });

      expect(confirmCalls, 1);
      expect(requestCalls, 1);
    });
  });

  group('BatteryOptimizationService simple wrappers', () {
    test('isIgnoringBatteryOptimizations is false on non-Android without calling through',
        () async {
      var calls = 0;
      final service = BatteryOptimizationService(
        isAndroidOverride: false,
        isIgnoringBatteryOptimizationsOverride: () async {
          calls++;
          return true;
        },
      );

      expect(await service.isIgnoringBatteryOptimizations(), isFalse);
      expect(calls, 0);
    });

    test('requestIgnoreBatteryOptimizations is false on non-Android without calling through',
        () async {
      var calls = 0;
      final service = BatteryOptimizationService(
        isAndroidOverride: false,
        requestIgnoreBatteryOptimizationsOverride: () async {
          calls++;
          return true;
        },
      );

      expect(await service.requestIgnoreBatteryOptimizations(), isFalse);
      expect(calls, 0);
    });
  });
}
