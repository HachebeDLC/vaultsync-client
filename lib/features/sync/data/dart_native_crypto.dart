import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:pointycastle/export.dart';

/// High-performance cryptographic engine providing hardware-accelerated 
/// AES-256-CBC encryption and delta-sync block hashing in Dart.
class DartNativeCrypto {
  static const int smallBlockSize = 256 * 1024;
  static const int largeBlockSize = 1024 * 1024;
  static const int blockThreshold = 10 * 1024 * 1024;
  static const int ivSize = 16;
  static const int paddingSize = 16;
  static const String magicHeader = 'NEOSYNC';
  static const int overhead = 7 + ivSize + paddingSize;
  
  static int getBlockSize(int fileSize) => fileSize >= blockThreshold ? largeBlockSize : smallBlockSize;
  static int getEncryptedBlockSize(int fileSize) => getBlockSize(fileSize) + overhead;
  
  static final _magicBytes = utf8.encode(magicHeader);

  /// Returns standard file metadata (size and lastModified) for a given local path.
  static Future<Map<String, dynamic>?> getFileInfo(String path) async {
    final file = File(path);
    if (!await file.exists()) return null;
    final stat = await file.stat();
    return {
      'size': stat.size,
      'lastModified': stat.modified.millisecondsSinceEpoch,
    };
  }

  /// Computes a full-file SHA-256 hash for identification purposes.
  static Future<String> calculateHash(String path) async {
    final file = File(path);
    final firstHash = await sha256.bind(file.openRead()).first;
    // The Kotlin engine accidentally computes a double-hash for the full file:
    // cryptoEngine.calculateHash(digest.digest(), digest.digest().size)
    // We must replicate this exactly so Desktop matches the server's stored hashes.
    final secondHash = sha256.convert(firstHash.bytes);
    return secondHash.toString();
  }

  /// Computes a JSON list of SHA-256 hashes for every 1MB block of the file.
  /// If `masterKey` is provided, hashes are computed over the encrypted blocks.
  static Future<String> calculateBlockHashes(String path, {String? masterKey}) async {
    final file = File(path);
    final raf = await file.open(mode: FileMode.read);
    final length = await raf.length();
    final blockSize = getBlockSize(length);
    final hashes = <String>[];
    
    Uint8List? keyBytes;
    PaddedBlockCipher? cipher;
    if (masterKey != null) {
      final decoded = base64Url.decode(masterKey);
      keyBytes = Uint8List.fromList(decoded.sublist(0, 32));
      cipher = PaddedBlockCipher('AES/CBC/PKCS7');
    }

    int offset = 0;
    while (offset < length) {
      await raf.setPosition(offset);
      final buffer = await raf.read(blockSize);
      if (buffer.isEmpty) break;
      
      if (keyBytes != null && cipher != null) {
        final iv = md5.convert(buffer).bytes;
        cipher.init(true, PaddedBlockCipherParameters(ParametersWithIV(KeyParameter(keyBytes), Uint8List.fromList(iv)), null));
        final encryptedBytes = cipher.process(Uint8List.fromList(buffer));
        
        final outBuffer = BytesBuilder();
        outBuffer.add(_magicBytes);
        outBuffer.add(iv);
        outBuffer.add(encryptedBytes);
        
        hashes.add(sha256.convert(outBuffer.toBytes()).toString());
      } else {
        hashes.add(sha256.convert(buffer).toString());
      }
      
      offset += buffer.length;
    }
    await raf.close();
    return json.encode(hashes);
  }

  /// Orchestrates a high-speed multi-threaded block upload of a file to the server.
  static Future<void> uploadFileNative(Map<String, dynamic> args) async {
    final url = args['url'] as String;
    final token = args['token'] as String?;
    final masterKey = args['masterKey'] as String?;
    final remotePath = args['remotePath'] as String;
    final uriStr = args['uri'] as String;
    final hash = args['hash'] as String;
    final deviceName = args['deviceName'] as String? ?? 'Linux';
    final updatedAt = args['updatedAt'] as int? ?? 0;
    final dirtyIndices = (args['dirtyIndices'] as List?)?.cast<int>();

    final file = File(uriStr);
    final fileSize = await file.length();
    final blockSize = getBlockSize(fileSize);
    final encryptedBlockSize = getEncryptedBlockSize(fileSize);
    final totalBlocks = fileSize == 0 ? 1 : ((fileSize + blockSize - 1) ~/ blockSize);
    final indicesToSync = dirtyIndices ?? List.generate(totalBlocks, (i) => i);

    final raf = await file.open(mode: FileMode.read);

    Uint8List? keyBytes;
    if (masterKey != null) {
      final decoded = base64Url.decode(masterKey);
      keyBytes = Uint8List.fromList(decoded.sublist(0, 32));
    }

    final client = http.Client();
    try {
      for (int i = 0; i < indicesToSync.length; i += 4) {
        final batch = indicesToSync.skip(i).take(4).toList();
        final futures = <Future<void>>[];
        
        for (final index in batch) {
          final offset = index * blockSize;
          await raf.setPosition(offset);
          final blockData = await raf.read(blockSize);
          
          futures.add(() async {
            List<int> uploadData;
            
            if (keyBytes != null && blockData.isNotEmpty) {
              final iv = md5.convert(blockData).bytes;
              // Note: PaddedBlockCipher is not thread-safe, but since we are in separate 
              // futures that don't share the instance yet (we hoist it but use new per-future), 
              // actually for parallel upload we SHOULD keep it per-future if they run concurrently.
              // However, the plan says hoist from inner loops. 
              // In this specific concurrent case, we instantiate once per block in the future.
              // I will optimize by instantiating once per BATCH if possible, but each future
              // in the batch runs concurrently. 
              // So I will instantiate once at the start of the future.
              final cipher = PaddedBlockCipher('AES/CBC/PKCS7')..init(true, PaddedBlockCipherParameters(ParametersWithIV(KeyParameter(keyBytes), Uint8List.fromList(iv)), null));
              final encryptedBytes = cipher.process(Uint8List.fromList(blockData));
              
              final outBuffer = BytesBuilder();
              outBuffer.add(_magicBytes);
              outBuffer.add(iv);
              outBuffer.add(encryptedBytes);
              uploadData = outBuffer.toBytes();
            } else {
              uploadData = blockData;
            }

            final encryptedOffset = index * encryptedBlockSize;
            
            final request = http.Request('POST', Uri.parse(url));
            if (token != null) request.headers['Authorization'] = 'Bearer $token';
            request.headers['x-vaultsync-path'] = remotePath;
            request.headers['x-vaultsync-index'] = index.toString();
            request.headers['x-vaultsync-offset'] = encryptedOffset.toString();
            request.headers['Content-Type'] = 'application/octet-stream';
            request.bodyBytes = uploadData;
            
            final response = await client.send(request);
            if (response.statusCode != 200) throw Exception('Block $index: HTTP ${response.statusCode}');
            // Read stream to release connection
            await response.stream.drain();
          }());
        }
        await Future.wait(futures);
      }
    } finally {
      await raf.close();
      client.close();
    }

    final finalizeUrl = url.endsWith('/') ? '${url}finalize' : '$url/finalize';
    final finReq = http.Request('POST', Uri.parse(finalizeUrl));
    if (token != null) finReq.headers['Authorization'] = 'Bearer $token';
    finReq.headers['Content-Type'] = 'application/json';
    finReq.body = json.encode({
      'path': remotePath,
      'hash': hash,
      'size': fileSize,
      'updated_at': updatedAt,
      'device_name': deviceName,
    });
    final finRes = await finReq.send();
    if (finRes.statusCode != 200) throw Exception('Finalization failed: HTTP ${finRes.statusCode}');
  }

  /// Performs a chunked, streaming download and decryption of a file from the server.
  static Future<void> downloadFileNative(Map<String, dynamic> args) async {
    final url = args['url'] as String;
    final token = args['token'] as String?;
    final masterKey = args['masterKey'] as String?;
    final remoteFilename = args['remoteFilename'] as String;
    final uriStr = args['uri'] as String; 
    final localFilename = args['localFilename'] as String;
    final patchIndices = (args['patchIndices'] as List?)?.cast<int>();
    final versionId = args['versionId'] as String?;
    final updatedAt = args['updatedAt'] as int?;
    final fileSize = args['fileSize'] as int? ?? 0;
    final blockSize = getBlockSize(fileSize);
    final encryptedBlockSize = getEncryptedBlockSize(fileSize);

    if (localFilename.contains('..')) throw Exception('Invalid path');

    Uint8List? keyBytes;
    if (masterKey != null) {
      final decoded = base64Url.decode(masterKey);
      keyBytes = Uint8List.fromList(decoded.sublist(0, 32));
    }

    final reqBody = <String, dynamic>{'path': remoteFilename};
    if (patchIndices != null) {
      reqBody['indices'] = patchIndices;
    } else if (versionId != null) {
      reqBody['versionId'] = versionId;
    } else {
      reqBody['filename'] = remoteFilename;
    }
    
    final request = http.Request('POST', Uri.parse(url));
    if (token != null) request.headers['Authorization'] = 'Bearer $token';
    request.headers['Content-Type'] = 'application/json';
    request.body = json.encode(reqBody);

    final response = await request.send();
    if (response.statusCode != 200) throw Exception('Download failed: HTTP ${response.statusCode}');

    final targetPath = localFilename.startsWith('/') ? localFilename : '$uriStr/$localFilename';
    final file = File(targetPath);
    if (!await file.parent.exists()) await file.parent.create(recursive: true);

    final tmpFile = File('$targetPath.vstmp');
    if (patchIndices != null && await file.exists()) {
      await file.copy(tmpFile.path); 
    }
    
    final raf = await tmpFile.open(mode: patchIndices != null ? FileMode.append : FileMode.write);

    final expectedBlockSize = keyBytes != null ? encryptedBlockSize : blockSize;
    
    await processDownloadStream(
      response.stream,
      raf,
      keyBytes,
      patchIndices,
      expectedBlockSize,
      blockSize,
    );
    
    await raf.close();
    if (await file.exists()) await file.delete();
    await tmpFile.rename(file.path);
    
    if (updatedAt != null) {
      // Dart's File.setLastModified expects a DateTime object
      await file.setLastModified(DateTime.fromMillisecondsSinceEpoch(updatedAt));
    }
  }

  static Future<void> processDownloadStream(
    Stream<List<int>> stream,
    RandomAccessFile raf,
    Uint8List? keyBytes,
    List<int>? patchIndices,
    int expectedBlockSize,
    int blockSize
  ) async {
    int currentIdx = 0;
    final ringBuffer = Uint8List(expectedBlockSize * 2);
    int bufferLen = 0;

    PaddedBlockCipher? cipher;
    if (keyBytes != null) {
      cipher = PaddedBlockCipher("AES/CBC/PKCS7");
    }

    await for (final chunk in stream) {
      int chunkOffset = 0;
      while (chunkOffset < chunk.length) {
        final spaceAvailable = ringBuffer.length - bufferLen;
        if (spaceAvailable == 0) throw Exception("Buffer overflow");
        
        final toCopy = (chunk.length - chunkOffset) < spaceAvailable ? (chunk.length - chunkOffset) : spaceAvailable;
        ringBuffer.setRange(bufferLen, bufferLen + toCopy, chunk.sublist(chunkOffset, chunkOffset + toCopy));
        bufferLen += toCopy;
        chunkOffset += toCopy;

        while (bufferLen >= expectedBlockSize) {
          final currentChunk = Uint8List.view(ringBuffer.buffer, 0, expectedBlockSize);
          List<int> decryptedData = _decryptBlock(currentChunk, keyBytes, cipher);
          
          final blockIndex = patchIndices != null ? patchIndices[currentIdx] : currentIdx;
          await raf.setPosition(blockIndex * blockSize);
          await raf.writeFrom(decryptedData);
          currentIdx++;

          final remaining = bufferLen - expectedBlockSize;
          if (remaining > 0) {
            ringBuffer.setRange(0, remaining, ringBuffer, expectedBlockSize);
          }
          bufferLen = remaining;
        }
      }
    }
    
    if (bufferLen > 0) {
      final currentChunk = Uint8List.view(ringBuffer.buffer, 0, bufferLen);
      List<int> decryptedData = _decryptBlock(currentChunk, keyBytes, cipher);
      final blockIndex = patchIndices != null ? patchIndices[currentIdx] : currentIdx;
      await raf.setPosition(blockIndex * blockSize);
      await raf.writeFrom(decryptedData);
    }
  }

  static List<int> _decryptBlock(Uint8List currentChunk, Uint8List? keyBytes, [PaddedBlockCipher? cipher]) {
    if (keyBytes != null) {
      if (currentChunk.length < 7 + 16) return Uint8List.fromList(currentChunk);
      bool match = true;
      for (int i = 0; i < 7; i++) {
        if (currentChunk[i] != _magicBytes[i]) { match = false; break; }
      }
      if (!match) return Uint8List.fromList(currentChunk);
      
      final iv = Uint8List.fromList(currentChunk.sublist(7, 7 + 16));
      final ciphertext = Uint8List.fromList(currentChunk.sublist(7 + 16));
      
      final useCipher = cipher ?? PaddedBlockCipher("AES/CBC/PKCS7");
      useCipher.init(false, PaddedBlockCipherParameters(ParametersWithIV(KeyParameter(keyBytes), iv), null));
      return useCipher.process(ciphertext);
    }
    return Uint8List.fromList(currentChunk);
  }
}
