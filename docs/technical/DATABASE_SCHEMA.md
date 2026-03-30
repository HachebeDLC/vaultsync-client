# Database Schema and State Management

VaultSync uses an SQLite-based database (via the `sqflite` Flutter plugin) to track the synchronization status of every file and its individual blocks.

## 1. The `sync_state` Table

The database schema is defined in `lib/features/sync/data/sync_state_database.dart`. It uses a single table to store all local file metadata.

```sql
CREATE TABLE sync_state(
  path TEXT PRIMARY KEY,       -- Local URI (file://, content://, or shizuku://)
  size INTEGER,                -- File size in bytes
  last_modified INTEGER,       -- Epoch timestamp
  hash TEXT,                   -- Full file SHA-256 hash
  status TEXT,                 -- synced, pending_upload, pending_download, failed
  system_id TEXT,              -- e.g., 'ps2', 'retroarch'
  remote_path TEXT,            -- Path on the server
  rel_path TEXT,               -- Relative path within the system
  error TEXT,                  -- Last error message (if status is 'failed')
  block_hashes TEXT,           -- JSON array of block SHA-256 hashes
  retry_count INTEGER DEFAULT 0
);
```

## 2. Sync States

- **`synced`**: Local and remote versions are in sync.
- **`pending_upload`**: Local changes detected; waiting for the background upload job to pick it up.
- **`pending_download`**: Remote changes detected; waiting for the background download job to pick it up.
- **`failed`**: A synchronization attempt failed. The `error` column contains the reason.

## 3. Efficient Queries

- **`idx_sync_status`**: An index on the `status` column to quickly retrieve pending jobs.
- **`findEntriesByBlockHash(blockHash)`**: Performs a `LIKE` search on the `block_hashes` JSON string. This is used for cross-file block deduplication, allowing the engine to recover identical blocks from other local files.

## 4. Background Job Management

- **Process Manual Queue**: When a manual sync is triggered, the `SyncRepository` queries the database for all `pending_upload` and `pending_download` jobs for a specific system and executes them sequentially.
- **`triggerQueueProcessing`**: On Android, this registers a `Workmanager` background task to process the queue when the device is connected to a network.

## 5. Persistence and Recovery

- **Atomic Status Updates**: The database ensures that status updates (e.g., from `pending_upload` to `synced`) only happen after a successful server finalization call.
- **WAL Mode**: Uses Write-Ahead Logging (`PRAGMA journal_mode = WAL`) to allow concurrent reads and writes without blocking.
