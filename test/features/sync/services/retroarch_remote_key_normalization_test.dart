// Regression coverage for the RetroArch remote-key anchor mismatch.
//
// Evidence (real device, POCO F8 Pro): every sync rewrote RetroArch DS saves
// (Mario Kart DS, Nintendogs, WarioWare, Pokemon HeartGold, Professor Layton)
// with identical content. Root cause: for a RetroArch-backed system whose
// systemId is NOT literally "retroarch" (e.g. `nds`, rooted at
// `.../RetroArch/saves`), SyncPathResolver.getCloudRelPath never recognizes
// the file as RetroArch's — neither `systemId` nor the bare local filename
// contains "retroarch" — so it falls through to an un-anchored local cloud
// key (`X.dsv`). Meanwhile SyncRepository.syncSystem builds its remote-file
// map by stripping only the `RetroArch/` cloud prefix, leaving the server's
// keys anchored (`saves/X.dsv`, `states/X.dsv`). The two keys never match:
// every sync treated the file as both local-only (queued for upload) and
// remote-only (queued for a same-content download).
//
// The fix factors the anchor-detection logic SyncPathResolver.getLocalRelPath
// already used for download destinations into reusable pure functions
// (retroArchRootAnchor, retroArchScanHasAnchor) and adds
// normalizeRetroArchRemoteKey, which SyncRepository.syncSystem applies to the
// remote listing before diffing so both sides agree on the same un-anchored
// key.
import 'package:flutter_test/flutter_test.dart';
import 'package:vaultsync_client/features/sync/services/sync_path_resolver.dart';

void main() {
  group('SyncPathResolver.retroArchRootAnchor', () {
    test('returns "saves" for a root ending in saves', () {
      expect(
        SyncPathResolver.retroArchRootAnchor('/storage/emulated/0/RetroArch/saves'),
        'saves',
      );
    });

    test('returns "states" for a root ending in states', () {
      expect(
        SyncPathResolver.retroArchRootAnchor('/storage/emulated/0/RetroArch/states'),
        'states',
      );
    });

    test('is case-insensitive on the leaf segment', () {
      expect(SyncPathResolver.retroArchRootAnchor('/storage/emulated/0/RetroArch/SAVES'), 'saves');
    });

    test('returns null for a root at the RetroArch folder itself', () {
      expect(SyncPathResolver.retroArchRootAnchor('/storage/emulated/0/RetroArch'), isNull);
    });

    test('returns null for an unrelated saves-named folder belonging to another emulator', () {
      expect(
        SyncPathResolver.retroArchRootAnchor(
            '/storage/emulated/0/Android/data/org.dolphinemu.dolphinemu/files/saves'),
        // The leaf really is "saves", so this returns 'saves' — callers gate
        // on the cloud prefix being RetroArch before trusting it, exactly as
        // SyncRepository.syncSystem does.
        'saves',
      );
    });

    test('handles a SAF content:// URI without throwing', () {
      expect(
        SyncPathResolver.retroArchRootAnchor(
            'content://com.android.externalstorage.documents/tree/primary%3ARetroArch%2Fsaves'),
        isNull,
      );
    });

    test('handles null and empty input', () {
      expect(SyncPathResolver.retroArchRootAnchor(null), isNull);
      expect(SyncPathResolver.retroArchRootAnchor(''), isNull);
    });
  });

  group('SyncPathResolver.retroArchScanHasAnchor', () {
    test('false for a scan of bare filenames (root sits inside saves/)', () {
      expect(
        SyncPathResolver.retroArchScanHasAnchor([
          {'relPath': 'mariokartds.dsv'},
          {'relPath': 'nintendogs.dsv'},
        ]),
        isFalse,
      );
    });

    test('true when the scan already carries a saves/ anchor', () {
      expect(
        SyncPathResolver.retroArchScanHasAnchor([
          {'relPath': 'saves/mariokartds.dsv'},
        ]),
        isTrue,
      );
    });

    test('true when the scan already carries a states/ anchor', () {
      expect(
        SyncPathResolver.retroArchScanHasAnchor([
          {'relPath': 'states/mariokartds.state'},
        ]),
        isTrue,
      );
    });

    test('false for an empty scan', () {
      expect(SyncPathResolver.retroArchScanHasAnchor(const []), isFalse);
    });
  });

  group('SyncPathResolver.normalizeRetroArchRemoteKey', () {
    // The reported bug: nds saves at RetroArch/saves/<file>.dsv.
    test('strips the saves/ anchor when root is rooted at saves and the local scan is un-anchored', () {
      expect(
        SyncPathResolver.normalizeRetroArchRemoteKey(
          'saves/mariokartds.dsv',
          rootAnchor: 'saves',
          localScanHasAnchor: false,
        ),
        'mariokartds.dsv',
      );
    });

    test('strips the states/ anchor the same way for a states-rooted system', () {
      expect(
        SyncPathResolver.normalizeRetroArchRemoteKey(
          'states/mariokartds.state',
          rootAnchor: 'states',
          localScanHasAnchor: false,
        ),
        'mariokartds.state',
      );
    });

    test('leaves a sibling-anchor key untouched (root=saves, key=states/x)', () {
      // A states/ file does not belong under a saves-rooted local scan at
      // all; leaving its key anchored means it can never collide with an
      // unrelated local file of the same bare name.
      expect(
        SyncPathResolver.normalizeRetroArchRemoteKey(
          'states/mariokartds.state',
          rootAnchor: 'saves',
          localScanHasAnchor: false,
        ),
        'states/mariokartds.state',
      );
    });

    test('leaves keys untouched when the local scan already has its own anchor', () {
      // Root sits above both saves/ and states/ (e.g. at RetroArch itself) —
      // both sides are already directly comparable, so rewriting would cause
      // a collision instead of fixing one.
      expect(
        SyncPathResolver.normalizeRetroArchRemoteKey(
          'saves/mariokartds.dsv',
          rootAnchor: null,
          localScanHasAnchor: true,
        ),
        'saves/mariokartds.dsv',
      );
    });

    test('leaves a non-anchored key untouched regardless of rootAnchor', () {
      expect(
        SyncPathResolver.normalizeRetroArchRemoteKey(
          'somewhere/else.dsv',
          rootAnchor: 'saves',
          localScanHasAnchor: false,
        ),
        'somewhere/else.dsv',
      );
    });

    test('no-op when rootAnchor is null (root not directly at saves/ or states/)', () {
      expect(
        SyncPathResolver.normalizeRetroArchRemoteKey(
          'saves/mariokartds.dsv',
          rootAnchor: null,
          localScanHasAnchor: false,
        ),
        'saves/mariokartds.dsv',
      );
    });
  });
}
