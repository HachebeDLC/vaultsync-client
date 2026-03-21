import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:pointycastle/export.dart';

class DartNativeCrypto {
  static const int blockSize = 1024 * 1024;
  static const int ivSize = 16;
  static const int paddingSize = 16;
  static const String magicHeader = 'NEOSYNC';
  static const int overhead = 7 + ivSize + paddingSize;
  static const int encryptedBlockSize = blockSize + overhead;
  
  static final _magicBytes = utf8.encode(magicHeader);

  static Future<Map<String, dynamic>?> getFileInfo(String path) async {
    final file = File(path);
    if (!await file.exists()) return null;
    final stat = await file.stat();
    return {
      'size': stat.size,
      'lastModified': stat.modified.millisecondsSinceEpoch,
    };
  }

  static Future<String> calculateHash(String path) async {
    final file = File(path);
    final hashBytes = await sha256.bind(file.openRead()).first;
    return hashBytes.toString();
  }

  static Future<String> calculateBlockHashes(String path) async {
    final file = File(path);
    final raf = await file.open(mode: FileMode.read);
    final length = await raf.length();
    final hashes = <String>[];
    
    int offset = 0;
    while (offset < length) {
      await raf.setPosition(offset);
      final buffer = await raf.read(blockSize);
      if (buffer.isEmpty) break;
      hashes.add(sha256.convert(buffer).toString());
      offset += buffer.length;
    }
    await raf.close();
    return json.encode(hashes);
  }

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

  static Future<void> downloadFileNative(Map<String, dynamic> args) async {
    final url = args['url'] as String;
    final token = args['token'] as String?;
    final masterKey = args['masterKey'] as String?;
    final remoteFilename = args['remoteFilename'] as String;
    final uriStr = args['uri'] as String; 
    final localFilename = args['localFilename'] as String;
    final patchIndices = (args['patchIndices'] as List?)?.cast<int>();
    final versionId = args['versionId'] as String?;

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
    
    int currentIdx = 0;
    final bytesBuffer = BytesBuilder();

    await for (final chunk in response.stream) {
      bytesBuffer.add(chunk);
      
      while (bytesBuffer.length >= expectedBlockSize) {
        final block = bytesBuffer.takeBytes();
        final currentChunk = block.sublist(0, expectedBlockSize);
        
        if (block.length > expectedBlockSize) {
          bytesBuffer.add(block.sublist(expectedBlockSize));
        }
        
        List<int> decryptedData;
        if (keyBytes != null) {
          if (currentChunk.length < 7 + 16) {
             decryptedData = currentChunk;
          } else {
             bool match = true;
             for (int i = 0; i < 7; i++) {
               if (currentChunk[i] != _magicBytes[i]) { match = false; break; }
             }
             if (!match) {
               decryptedData = currentChunk;
             } else {
               final iv = Uint8List.fromList(currentChunk.sublist(7, 7 + 16));
               final ciphertext = Uint8List.fromList(currentChunk.sublist(7 + 16));
               final cipher = PaddedBlockCipher('AES/CBC/PKCS7')..init(false, PaddedBlockCipherParameters(ParametersWithIV(KeyParameter(keyBytes), iv), null));
               decryptedData = cipher.process(ciphertext);
             }
          }
        } else {
          decryptedData = currentChunk;
        }
        
        final blockIndex = patchIndices != null ? patchIndices[currentIdx] : currentIdx;
        await raf.setPosition(blockIndex * blockSize);
        await raf.writeFrom(decryptedData);
        currentIdx++;
      }
    }
    
    if (bytesBuffer.isNotEmpty) {
      final currentChunk = bytesBuffer.takeBytes();
      List<int> decryptedData;
      if (keyBytes != null) {
        if (currentChunk.length < 7 + 16) {
           decryptedData = currentChunk;
        } else {
           bool match = true;
           for (int i = 0; i < 7; i++) {
             if (currentChunk[i] != _magicBytes[i]) { match = false; break; }
           }
           if (!match) {
             decryptedData = currentChunk;
           } else {
             final iv = Uint8List.fromList(currentChunk.sublist(7, 7 + 16));
             final ciphertext = Uint8List.fromList(currentChunk.sublist(7 + 16));
             final cipher = PaddedBlockCipher('AES/CBC/PKCS7')..init(false, PaddedBlockCipherParameters(ParametersWithIV(KeyParameter(keyBytes), iv), null));
             decryptedData = cipher.process(ciphertext);
           }
        }
      } else {
        decryptedData = currentChunk;
      }
      
      final blockIndex = patchIndices != null ? patchIndices[currentIdx] : currentIdx;
      await raf.setPosition(blockIndex * blockSize);
      await raf.writeFrom(decryptedData);
    }
    
    await raf.close();
    if (await file.exists()) await file.delete();
    await tmpFile.rename(file.path);
  }
}
