import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../sync/services/system_path_service.dart';

class DiagnosticsScreen extends StatefulWidget {
  const DiagnosticsScreen({super.key});

  @override
  State<DiagnosticsScreen> createState() => _DiagnosticsScreenState();
}

class _DiagnosticsScreenState extends State<DiagnosticsScreen> {
  final List<String> _logs = [];
  bool _isRunning = false;
  static const _platform = MethodChannel('com.vaultsync.app/launcher');

  void _log(String message) {
    setState(() => _logs.add(message));
  }

  Future<void> _runTests(WidgetRef ref) async {
    setState(() {
      _logs.clear();
      _isRunning = true;
    });

    _log('🚀 Starting Phase 2 Diagnostics...');

    try {
      // 1. Android & SDK
      final sdk = await _platform.invokeMethod<int>('getAndroidVersion') ?? 0;
      _log('📱 SDK Level: $sdk');
      _log(sdk <= 33 ? '✅ Mode: Legacy Handheld (POSIX)' : '✅ Mode: Modern Android (Bridge)');

      // 2. Metadata Consistency
      _log('📁 Testing Metadata Parity...');
      final tempDir = await Directory.systemTemp.createTemp('vs_diag');
      final testFile = File('${tempDir.path}/meta.bin');
      await testFile.writeAsBytes(Uint8List(1024));
      
      final nativeInfo = await _platform.invokeMapMethod('getFileInfo', {'uri': testFile.path});
      if (nativeInfo != null && nativeInfo['size'] == 1024) {
        _log('✅ Metadata matches (Native size 1024 bytes)');
      } else {
        _log('❌ Metadata mismatch: $nativeInfo');
      }

      // 3. Delta Sync Precision Test
      _log('⚡ Testing Delta Block Precision (2MB)...');
      final blockA = List<int>.generate(1024 * 1024, (i) => i % 256);
      final blockB = List<int>.generate(1024 * 1024, (i) => (i + 1) % 256);
      final testData = Uint8List.fromList([...blockA, ...blockB]);
      
      final deltaFile = File('${tempDir.path}/delta.bin');
      await deltaFile.writeAsBytes(testData);

      final String initialBlocksJson = await _platform.invokeMethod('calculateBlockHashes', {'path': deltaFile.path});
      final List initialHashes = json.decode(initialBlocksJson);
      _log('📍 Initial Blocks: ${initialHashes.length}');

      // Modify 1 byte in block 2 (Offset 1.5MB)
      final modifiedData = Uint8List.fromList(testData);
      modifiedData[1572864] = (modifiedData[1572864] + 1) % 256;
      await deltaFile.writeAsBytes(modifiedData);

      final String modifiedBlocksJson = await _platform.invokeMethod('calculateBlockHashes', {'path': deltaFile.path});
      final List modifiedHashes = json.decode(modifiedBlocksJson);

      final dirty = <int>[];
      for (int i = 0; i < modifiedHashes.length; i++) {
        if (initialHashes[i] != modifiedHashes[i]) dirty.add(i);
      }

      if (dirty.length == 1 && dirty.first == 1) {
        _log('✅ Delta Accuracy: Correct (Only Block 1 identified)');
      } else {
        _log('❌ Delta Failure: Identified $dirty');
      }

      // 4. Shizuku Status
      _log('🛡️ Checking Shizuku...');
      final shizuku = await _platform.invokeMethod<Map>('checkShizukuStatus');
      if (shizuku != null) {
        _log('Running: ${shizuku['running']}, Authorized: ${shizuku['authorized']}');
      } else {
        _log('⚠️ Shizuku unavailable.');
      }

      // 5. Native Cache Speed
      _log('🚀 Benchmarking Native Cache...');
      const pspPath = '/storage/emulated/0/PSP/SAVEDATA';
      final sw = Stopwatch()..start();
      try {
        await _platform.invokeMethod('scanRecursive', {'path': pspPath, 'systemId': 'diag', 'ignoredFolders': []});
        final t1 = sw.elapsedMilliseconds;
        sw.reset(); sw.start();
        await _platform.invokeMethod('scanRecursive', {'path': pspPath, 'systemId': 'diag', 'ignoredFolders': []});
        final t2 = sw.elapsedMilliseconds;
        _log('⏱️ Cold Scan: ${t1}ms | Cached: ${t2}ms');
        if (t2 < t1) _log('✅ Cache speedup confirmed.');
      } catch (_) {
        _log('⚠️ Skip Cache Test: $pspPath not found.');
      }

    } catch (e) {
      _log('❌ DIAG ERROR: $e');
    } finally {
      setState(() => _isRunning = false);
      _log('🏁 All checks complete.');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('System Diagnostics')),
      backgroundColor: Colors.black,
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Consumer(builder: (context, ref, _) => ElevatedButton.icon(
              onPressed: _isRunning ? null : () => _runTests(ref),
              icon: _isRunning ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.speed),
              label: Text(_isRunning ? 'Running Stress Tests...' : 'Start Delta Sync Test'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blue.shade900,
                foregroundColor: Colors.white,
                minimumSize: const Size(double.infinity, 60),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))
              ),
            )),
          ),
          Expanded(
            child: Container(
              width: double.infinity,
              margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFF121212),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.blue.withOpacity(0.3))
              ),
              child: ListView.builder(
                itemCount: _logs.length,
                itemBuilder: (context, i) {
                  final log = _logs[i];
                  Color color = Colors.greenAccent;
                  if (log.contains('❌')) color = Colors.redAccent;
                  if (log.contains('⚠️')) color = Colors.orangeAccent;
                  if (log.contains('🚀')) color = Colors.blueAccent;
                  
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Text(log, style: TextStyle(color: color, fontFamily: 'monospace', fontSize: 13, height: 1.4)),
                  );
                },
              ),
            ),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}
