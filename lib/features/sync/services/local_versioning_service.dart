import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:vaultsync_client/core/services/vaultsync_launcher.dart';
import 'package:vaultsync_client/features/sync/data/sync_state_database.dart';
import 'package:vaultsync_client/features/sync/data/sync_repository.dart';

final localVersioningServiceProvider = Provider((ref) {
  return LocalVersioningService(
    ref.watch(syncStateDatabaseProvider),
    ref.watch(vaultSyncLauncherProvider),
  );
});

class LocalVersioningService {
  final SyncStateDatabase _db;
  final VaultSyncLauncher _launcher;
  final String? _storePathOverride;
  static const int _maxVersions = 5;

  LocalVersioningService(this._db, this._launcher, [this._storePathOverride]);

  Future<String> _getVersionStorePath() async {
    if (_storePathOverride != null) return _storePathOverride!;
    final dir = await getApplicationSupportDirectory();
    return p.join(dir.path, 'versions');
  }

  Future<String?> createSnapshot(String systemId, String filePath, int size, {String? masterKey}) async {
    try {
      final db = await _db.database;
      final previousState = await _db.getState(filePath);
      
      List<String> previousHashes = [];
      if (previousState != null && previousState['block_hashes'] != null) {
        previousHashes = List<String>.from(jsonDecode(previousState['block_hashes']));
      }

      final hashResult = await _launcher.calculateBlockHashesAndHash(filePath, masterKey: masterKey);
      if (hashResult == null) return null;

      final currentHashes = List<String>.from(hashResult['blockHashes']);
      final fileHash = hashResult['fileHash'] as String;

      final changedBlocks = <int, bool>{};
      for (int i = 0; i < currentHashes.length; i++) {
        if (i >= previousHashes.length || currentHashes[i] != previousHashes[i]) {
          changedBlocks[i] = true;
        } else {
          changedBlocks[i] = false;
        }
      }

      final versionStorePath = await _getVersionStorePath();
      final extracted = await _launcher.extractModifiedBlocks(filePath, changedBlocks, versionStorePath);
      
      if (!extracted) return null;

      final versionId = 'v_${DateTime.now().millisecondsSinceEpoch}';

      await db.transaction((txn) async {
        await txn.insert('local_versions', {
          'id': versionId,
          'systemId': systemId,
          'filePath': filePath,
          'timestamp': DateTime.now().millisecondsSinceEpoch,
          'size': size,
          'fileHash': fileHash,
        });

        for (int i = 0; i < currentHashes.length; i++) {
          await txn.insert('version_blocks', {
            'versionId': versionId,
            'blockIndex': i,
            'blockHash': currentHashes[i],
          });
        }

        // Apply retention policy
        final versions = await txn.query(
          'local_versions',
          where: 'systemId = ? AND filePath = ?',
          whereArgs: [systemId, filePath],
          orderBy: 'timestamp ASC',
        );

        if (versions.length > _maxVersions) {
          final toDelete = versions.take(versions.length - _maxVersions);
          for (final v in toDelete) {
            await txn.delete(
              'local_versions',
              where: 'id = ?',
              whereArgs: [v['id']],
            );
            // version_blocks cascade delete handles the block references
          }
        }
      });

      return versionId;
    } catch (e) {
      print('Error creating snapshot: $e');
      return null;
    }
  }

  Future<List<Map<String, dynamic>>> getVersions(String systemId, String filePath) async {
    final db = await _db.database;
    return await db.query(
      'local_versions',
      where: 'systemId = ? AND filePath = ?',
      whereArgs: [systemId, filePath],
      orderBy: 'timestamp DESC',
    );
  }

  Future<bool> reconstructVersion(String versionId, String liveFilePath, String restorePath) async {
    try {
      final db = await _db.database;
      final blocks = await db.query(
        'version_blocks',
        where: 'versionId = ?',
        whereArgs: [versionId],
        orderBy: 'blockIndex ASC',
      );

      if (blocks.isEmpty) return false;

      final layoutHashes = blocks.map((b) => b['blockHash'] as String).toList();
      final versionStorePath = await _getVersionStorePath();

      return await _launcher.reconstructFromDeltas(layoutHashes, liveFilePath, restorePath, versionStorePath);
    } catch (e) {
      print('Error reconstructing version: $e');
      return false;
    }
  }
}
