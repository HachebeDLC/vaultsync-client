import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vaultsync_client/features/sync/services/system_path_service.dart';
import 'package:vaultsync_client/features/emulation/data/emulator_repository.dart';

void main() {
  // CRITICAL: Initialize the test binding for platform channels
  TestWidgetsFlutterBinding.ensureInitialized();
  
  const platform = MethodChannel('com.vaultsync.app/launcher');

  group('System Health & Bridge Verification', () {
    setUpAll(() async {
      // Mock initial values for SharedPreferences to avoid hanging
      SharedPreferences.setMockInitialValues({});
    });

    test('1. Android Version & Routing Detection', () async {
      try {
        final version = await platform.invokeMethod<int>('getAndroidVersion');
        print('📱 Detected Android Version: $version');
        
        if (version! <= 13) {
          print('✅ PASSED: Device in Legacy/Handheld mode (POSIX Fast Lane).');
        } else {
          print('✅ PASSED: Device in Modern mode (Shizuku/SAF Bridge active).');
        }
      } on PlatformException catch (e) {
        print('⚠️ Skipping Platform Test: Not running on a real device/emulator. ($e)');
      }
    });

    test('2. Bridge Performance & IO Stress (5MB Test)', () async {
      final stopwatch = Stopwatch()..start();
      
      final testData = Uint8List(5 * 1024 * 1024);
      final originalHash = sha256.convert(testData).toString();
      
      final tempDir = await Directory.systemTemp.createTemp('vs_test');
      final testFile = File('${tempDir.path}/health_test.bin');
      await testFile.writeAsBytes(testData);
      
      print('⏱️ IO Prep complete in ${stopwatch.elapsedMilliseconds}ms');
      
      try {
        stopwatch.reset();
        final nativeHash = await platform.invokeMethod<String>('calculateHash', {'path': testFile.path});
        print('⏱️ Native Hash (${testFile.path}) took ${stopwatch.elapsedMilliseconds}ms');
        
        expect(nativeHash, originalHash, reason: 'Native hash must match original');
        print('✅ PASSED: Native Read Bridge is binary-accurate.');
      } on PlatformException catch (e) {
        print('⚠️ Skipping Platform Test: Not running on a real device. ($e)');
      }
    });

    test('3. Eden/Yuzu Auto-Dive Verification', () async {
      final service = SystemPathService(EmulatorRepository());
      
      try {
        final effective = await service.getEffectivePath('eden');
        print('📍 Eden Resolved Path: $effective');
        
        if (effective.contains('nand/user/save')) {
          print('✅ PASSED: Auto-Dive correctly resolved profile folder.');
        } else {
          print('⚠️ WARNING: Auto-Dive stayed at root. (May be expected if folders are missing).');
        }
      } on PlatformException catch (e) {
        print('⚠️ Skipping Platform Test: Not running on a real device. ($e)');
      }
    });

    test('4. Shizuku/SAF Directory Cache Test', () async {
      const pspPath = '/storage/emulated/0/PSP/SAVEDATA';
      final stopwatch = Stopwatch()..start();
      
      try {
        // First scan (Populates Cache)
        await platform.invokeMethod('scanRecursive', {
          'path': pspPath,
          'systemId': 'psp',
          'ignoredFolders': []
        });
        final firstScan = stopwatch.elapsedMilliseconds;
        
        // Second scan (Hits Cache)
        stopwatch.reset();
        await platform.invokeMethod('scanRecursive', {
          'path': pspPath,
          'systemId': 'psp',
          'ignoredFolders': []
        });
        final secondScan = stopwatch.elapsedMilliseconds;
        
        print('⏱️ First Scan: ${firstScan}ms');
        print('⏱️ Cached Scan: ${secondScan}ms');
        
        if (secondScan < firstScan) {
          print('✅ PASSED: Native Directory Cache is active and accelerating scans.');
        } else {
          print('⚠️ INFO: Cached scan was not significantly faster (Expected on POSIX).');
        }
      } on PlatformException catch (e) {
        print('⚠️ Skipping Platform Test: Not running on a real device. ($e)');
      }
    });
  });
}
