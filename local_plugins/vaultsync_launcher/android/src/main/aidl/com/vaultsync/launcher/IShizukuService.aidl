package com.vaultsync.launcher;

import android.os.ParcelFileDescriptor;

interface IShizukuService {
    List<String> listFiles(String path) = 1;
    byte[] readFile(String path, long offset, int length) = 2;
    void writeFile(String path, in byte[] data, long offset) = 3;
    boolean setLastModified(String path, long time) = 4;
    boolean renameFile(String oldPath, String newPath) = 5;
    boolean deleteFile(String path) = 6;
    long getFileSize(String path) = 7;
    long getLastModified(String path) = 8;
    String calculateHash(String path) = 9;
    List<String> calculateBlockHashes(String path, int blockSize) = 10;
    ParcelFileDescriptor openFile(String path, String mode) = 11;
    
    // NEW: Batch metadata for zero-loop Binder scanning
    String listFileInfo(String path) = 12;

    boolean mkdirs(String path) = 13;
    
    void destroy() = 16777114;
}
