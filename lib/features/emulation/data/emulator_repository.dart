import 'dart:convert';
import 'dart:developer' as developer;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../domain/emulator_config.dart';

final emulatorRepositoryProvider = Provider<EmulatorRepository>((ref) {
  return EmulatorRepository();
});

class EmulatorRepository {
  Future<List<EmulatorConfig>> loadSystems() async {
    try {
      developer.log('Loading systems from AssetManifest...', name: 'VaultSync', level: 800);
      final AssetManifest manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
      final allAssets = manifest.listAssets();
      developer.log('Total assets in manifest: ${allAssets.length}', name: 'VaultSync', level: 800);
      
      final systemFiles = allAssets
          .where((String key) => key.contains('assets/systems/') && key.endsWith('.json'))
          .toList();

      developer.log('Found ${systemFiles.length} system files in manifest', name: 'VaultSync', level: 800);
      if (systemFiles.isEmpty) {
        developer.log('Sample asset keys: ${allAssets.take(10).join(', ')}', name: 'VaultSync', level: 800);
      }

      List<EmulatorConfig> systems = [];
      for (final file in systemFiles) {
        try {
          final String jsonString = await rootBundle.loadString(file);
          final Map<String, dynamic> jsonMap = json.decode(jsonString);
          systems.add(EmulatorConfig.fromJson(jsonMap));
        } catch (e) {
          developer.log('Error loading system file $file', name: 'VaultSync', level: 900, error: e);
        }
      }
      return systems;
    } catch (e) {
      developer.log('Error loading AssetManifest via new API', name: 'VaultSync', level: 900, error: e);
      // Fallback for older Flutter versions
      try {
        developer.log('Trying fallback manifest loading...', name: 'VaultSync', level: 800);
        final manifestContent = await rootBundle.loadString('AssetManifest.json');
        final Map<String, dynamic> manifest = json.decode(manifestContent);
        final systemFiles = manifest.keys
            .where((String key) => key.contains('assets/systems/') && key.endsWith('.json'))
            .toList();
        
        developer.log('Found ${systemFiles.length} system files in fallback manifest', name: 'VaultSync', level: 800);

        List<EmulatorConfig> systems = [];
        for (final file in systemFiles) {
          final String jsonString = await rootBundle.loadString(file);
          final Map<String, dynamic> jsonMap = json.decode(jsonString);
          systems.add(EmulatorConfig.fromJson(jsonMap));
        }
        return systems;
      } catch (e2) {
        developer.log('Fallback Error loading AssetManifest.json', name: 'VaultSync', level: 900, error: e2);
        return [];
      }
    }
  }
}
