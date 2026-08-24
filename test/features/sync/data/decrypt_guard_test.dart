import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/export.dart' hide Digest;
import 'package:vaultsync_client/features/sync/data/dart_native_crypto.dart';

// Pins the guard that turns a missing master key into a loud failure.
//
// `_decryptBlock` used to copy a block through unchanged when it lacked the
// NEOSYNC header, even with a key in hand. Nothing logged it: the raw
// ciphertext was written to disk as if it were the save, and the only clue was
// a size check further up the stack. That is why it survived for months.
//
//   * PS2 memory cards on one device ended up exactly 39 bytes too long
//     (magic 7 + IV 16 + padding 16) while still starting with a valid-looking
//     "Sony PS2 Memory Card Format" header, so the emulator reported damage;
//   * a later delta upload patched plaintext blocks over encrypted ones,
//     producing blobs whose length matched neither the database row nor any
//     device that tried to download them.
//
// An unreadable download is recoverable. A silently corrupted save is not.
void main() {
  final key = Uint8List.fromList(List<int>.generate(32, (i) => i));

  Uint8List plainBlock(int length) =>
      Uint8List.fromList(List<int>.filled(length, 0x41)); // 'A' * length

  /// Builds a real VaultSync block: magic + IV + AES-256-CBC/PKCS7 ciphertext.
  Uint8List encryptedBlock(List<int> plaintext, Uint8List keyBytes) {
    final iv = Uint8List.fromList(List<int>.generate(16, (i) => 0x10 + i));
    final cipher = PaddedBlockCipher('AES/CBC/PKCS7')
      ..init(
          true,
          PaddedBlockCipherParameters(
              ParametersWithIV(KeyParameter(keyBytes), iv), null));
    final out = BytesBuilder()
      ..add(utf8.encode(DartNativeCrypto.magicHeader))
      ..add(iv)
      ..add(cipher.process(Uint8List.fromList(plaintext)));
    return out.toBytes();
  }

  group('with a key', () {
    test('rejects a block that carries no NEOSYNC header', () {
      // Long enough to look like a candidate block, but it is not ciphertext.
      // Before the guard this returned the 'A's verbatim.
      expect(
        () => DartNativeCrypto.decryptBlockForTest(plainBlock(64), key),
        throwsA(predicate((e) => e.toString().contains('NEOSYNC'))),
      );
    });

    test('rejects a block shorter than magic + IV + one AES block', () {
      // 38 bytes: one short of the 39-byte minimum, so it cannot be ciphertext.
      expect(
        () => DartNativeCrypto.decryptBlockForTest(plainBlock(38), key),
        throwsA(predicate((e) => e.toString().contains('too short'))),
      );
    });

    test('the error names the recovery step', () {
      // On screen the symptom is an unrelated-looking size mismatch, so the
      // message has to point at the actual fix.
      try {
        DartNativeCrypto.decryptBlockForTest(plainBlock(64), key);
        fail('expected a throw');
      } catch (e) {
        expect(e.toString().toLowerCase(), contains('sign out'));
      }
    });

    test('a genuine encrypted block still round-trips', () {
      final payload = utf8.encode('a real save payload');
      final decrypted = DartNativeCrypto.decryptBlockForTest(
          encryptedBlock(payload, key), key);
      expect(utf8.decode(decrypted), 'a real save payload');
    });

    test('a block whose header is one byte off is rejected, not copied', () {
      final good = encryptedBlock(utf8.encode('payload'), key);
      final tampered = Uint8List.fromList(good)..[3] = 0x00;
      expect(
        () => DartNativeCrypto.decryptBlockForTest(tampered, key),
        throwsA(predicate((e) => e.toString().contains('NEOSYNC'))),
      );
    });
  });

  group('without a key', () {
    test('passes plaintext through untouched', () {
      // This path is legitimate and must keep working: the server answers
      // `x-vaultsync-encrypted: false` for blobs uploaded before encryption
      // existed, and the caller supplies no key. 37 such files are still on
      // the server today.
      final plain = plainBlock(64);
      expect(DartNativeCrypto.decryptBlockForTest(plain, null), plain);
    });

    test('passes a short block through too', () {
      final plain = plainBlock(12);
      expect(DartNativeCrypto.decryptBlockForTest(plain, null), plain);
    });
  });
}
