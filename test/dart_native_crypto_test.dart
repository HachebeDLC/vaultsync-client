import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:vaultsync_client/features/sync/data/dart_native_crypto.dart';
import 'dart:io';

class MockRandomAccessFile extends Mock implements RandomAccessFile {}

void main() {
  group('DartNativeCrypto Stream Processing', () {
    late MockRandomAccessFile mockRaf;

    setUp(() {
      mockRaf = MockRandomAccessFile();
      when(() => mockRaf.setPosition(any())).thenAnswer((_) async => mockRaf);
      when(() => mockRaf.writeFrom(any())).thenAnswer((_) async => mockRaf);
    });

    test('Should process small chunks into a full block', () async {
      const blockSize = 100; // Small block size for testing
      const expectedBlockSize = 100;
      
      final data = Uint8List.fromList(List.generate(100, (i) => i));
      // Split data into 10 chunks of 10 bytes
      final chunks = List.generate(10, (i) => data.sublist(i * 10, (i + 1) * 10));
      final stream = Stream.fromIterable(chunks);

      await DartNativeCrypto.processDownloadStream(
        stream,
        mockRaf,
        null, // No encryption for simple test
        null, // No patch indices
        expectedBlockSize,
        blockSize,
      );

      verify(() => mockRaf.setPosition(0)).called(1);
      verify(() => mockRaf.writeFrom(any(that: equals(data)))).called(1);
    });

    test('Should process multiple blocks with correct offsets', () async {
      const blockSize = 50;
      const expectedBlockSize = 50;
      
      final data = Uint8List.fromList(List.generate(100, (i) => i));
      // Stream in chunks of 33 bytes (misaligned with block size)
      final chunks = [
        data.sublist(0, 33),
        data.sublist(33, 66),
        data.sublist(66, 100),
      ];
      final stream = Stream.fromIterable(chunks);

      await DartNativeCrypto.processDownloadStream(
        stream,
        mockRaf,
        null,
        null,
        expectedBlockSize,
        blockSize,
      );

      // Block 1 (0-50)
      verify(() => mockRaf.setPosition(0)).called(1);
      verify(() => mockRaf.writeFrom(any(that: equals(data.sublist(0, 50))))).called(1);
      
      // Block 2 (50-100)
      verify(() => mockRaf.setPosition(50)).called(1);
      verify(() => mockRaf.writeFrom(any(that: equals(data.sublist(50, 100))))).called(1);
    });

    test('Should process partial trailing block', () async {
      const blockSize = 50;
      const expectedBlockSize = 50;
      
      final data = Uint8List.fromList(List.generate(75, (i) => i));
      final stream = Stream.fromIterable([data]);

      await DartNativeCrypto.processDownloadStream(
        stream,
        mockRaf,
        null,
        null,
        expectedBlockSize,
        blockSize,
      );

      // Block 1 (0-50)
      verify(() => mockRaf.setPosition(0)).called(1);
      verify(() => mockRaf.writeFrom(any(that: equals(data.sublist(0, 50))))).called(1);
      
      // Block 2 (Partial, 50-75)
      verify(() => mockRaf.setPosition(50)).called(1);
      verify(() => mockRaf.writeFrom(any(that: equals(data.sublist(50, 75))))).called(1);
    });
  });
}
