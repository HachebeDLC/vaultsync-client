# Sync Protocol & Delta-Sync Algorithm

VaultSync implements a custom delta-sync protocol to minimize bandwidth, significantly reducing transfer times for large emulator save files (e.g., memory cards and NAND folders).

## 1. Variable Block Sizes

The engine dynamically selects a block size based on the total file size to balance granularity with metadata overhead:

- **Small Files (< 10MB)**: Uses **256KB** blocks.
- **Large Files (≥ 10MB)**: Uses **1MB** blocks.

## 2. Sync Lifecycle

### Stage 1: Metadata Check
The Dart `SyncRepository` queries the server for the file list of a specific system (e.g., `prefix=ps2`).
- Compare local and remote `lastModified` and `size`.
- If identical, the file is skipped (if no force-sync is requested).

### Stage 2: Block-Level Delta Identification
If a file has changed:
1. The **native engine** (`FileScanner` and `CryptoEngine`) calculates SHA-256 hashes for every 1MB (or 256KB) block.
2. The list of hashes is sent to `/api/v1/blocks/check`.
3. The server compares these hashes against its own version and returns the indices of the "dirty" blocks.

### Stage 3: Sequential Transfer
- **Upload**: The `UploadManager` only sends the blocks identified as "dirty" to `/api/v1/upload`.
- **Download**: The `DownloadManager` requests only the missing blocks from `/api/v1/blocks/download`.

## 3. In-Place Patching

- **RandomAccessFile**: On both Android and Desktop, VaultSync uses `RandomAccessFile` (or equivalent `FileChannel`) to `seek` to specific offsets within a file.
- **Atomic Writes**: For downloads, the engine patches the existing file directly to avoid unnecessary large-scale data copying.
- **Zero-RAM overhead**: Using a 1MB streaming buffer ensures the app can sync multi-gigabyte files (e.g., 4GB NAND images) without exceeding 100MB of RAM usage.

## 4. Real-time Events (SSE)

VaultSync uses Server-Sent Events (SSE) for near-instant synchronization:
1. Device A uploads a new save.
2. The server sends an SSE payload to all other connected devices for that user.
3. Device B receives the event and automatically queues a download for the updated file.
