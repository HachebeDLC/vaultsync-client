package com.vaultsync.app;

interface IShizukuService {
    List<String> listFiles(String path);
    byte[] readFile(String path, long offset, int length);
    void writeFile(String path, in byte[] data, long offset);
    void destroy();
}
