package com.vaultsync.app;

interface IShizukuService {
    List<String> listFiles(String path) = 1;
    byte[] readFile(String path, long offset, int length) = 2;
    void writeFile(String path, in byte[] data, long offset) = 3;
    
    /**
     * Required by Shizuku to properly destroy the user service.
     * Transaction ID 16777114 is mandatory.
     */
    void destroy() = 16777114;
}
