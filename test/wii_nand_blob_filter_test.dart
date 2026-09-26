import 'package:flutter_test/flutter_test.dart';
import 'package:vaultsync_client/features/sync/services/sync_path_resolver.dart';

void main() {
  // Mirrors vaultsync_server/app/cleanup_garbage.py's _is_wii_nand_blob:
  //   top = path.split('/')[0].lower()
  //   if top not in ('wii', 'dolphin', 'gc'): return False
  //   return path.lower().endswith(('.app', '.tmd', '.wad'))
  group('SyncPathResolver.isWiiNandBlobCloudPath', () {
    test('matches a Wii NAND system title .app blob', () {
      expect(
        SyncPathResolver.isWiiNandBlobCloudPath('wii/00000001/00000002/content/00000001.app'),
        isTrue,
      );
    });

    test('matches a WiiWare channel .app blob', () {
      expect(
        SyncPathResolver.isWiiNandBlobCloudPath('wii/00010008/48414741/content/00000005.app'),
        isTrue,
      );
    });

    test('matches title.tmd metadata', () {
      expect(
        SyncPathResolver.isWiiNandBlobCloudPath('wii/00010001/524d4345/title.tmd'),
        isTrue,
      );
    });

    test('matches a .wad file', () {
      expect(
        SyncPathResolver.isWiiNandBlobCloudPath('wii/channel_backup/HAJE.wad'),
        isTrue,
      );
    });

    test('matches under the dolphin top segment', () {
      expect(
        SyncPathResolver.isWiiNandBlobCloudPath('dolphin/00000001/00000002/content/x.app'),
        isTrue,
      );
    });

    test('matches under the gc top segment', () {
      expect(
        SyncPathResolver.isWiiNandBlobCloudPath('gc/nand/x.tmd'),
        isTrue,
      );
    });

    test('is case-insensitive on both the top segment and the suffix', () {
      expect(
        SyncPathResolver.isWiiNandBlobCloudPath('WII/00010008/HAJE/CONTENT/X.APP'),
        isTrue,
      );
      expect(
        SyncPathResolver.isWiiNandBlobCloudPath('Dolphin/x/y.Tmd'),
        isTrue,
      );
    });

    test('does not match a real Wii save file', () {
      expect(
        SyncPathResolver.isWiiNandBlobCloudPath('wii/title/00010000/RSAE01/savedata.bin'),
        isFalse,
      );
    });

    test('does not match a real GC save (.gci)', () {
      expect(
        SyncPathResolver.isWiiNandBlobCloudPath('gc/card_a/01-GALE-Zelda.gci'),
        isFalse,
      );
    });

    test('does not match when the top segment is not wii/dolphin/gc, even with a matching suffix', () {
      expect(
        SyncPathResolver.isWiiNandBlobCloudPath('retroarch/saves/x.app'),
        isFalse,
      );
      expect(
        SyncPathResolver.isWiiNandBlobCloudPath('wiiu/x.app'),
        isFalse,
        reason: 'wiiu is a different, unrelated namespace and must not match on a "wii" prefix',
      );
    });

    test('does not match a .app-like extension that is not exactly .app/.tmd/.wad', () {
      expect(
        SyncPathResolver.isWiiNandBlobCloudPath('wii/x.application'),
        isFalse,
      );
    });

    test('handles an empty string without throwing', () {
      expect(SyncPathResolver.isWiiNandBlobCloudPath(''), isFalse);
    });

    test('handles a single-segment path without throwing', () {
      expect(SyncPathResolver.isWiiNandBlobCloudPath('wii'), isFalse);
    });
  });
}
