# Cryptography and Key Derivation

VaultSync follows a **Zero-Knowledge** model. Your data is encrypted locally before being sent to the server. The server never sees your unencrypted password, your master key, or your unencrypted save files.

## 1. Key Derivation

### Local Master Key (LMK)
During account registration/login:
1. The user's password is used to derive a 256-bit **Master Key** using PBKDF2 (on the server-side, it's stored only in salted-hash form).
2. The key is stored securely in the device's keychain (using `flutter_secure_storage`).

## 2. Convergent AES-256-CBC

VaultSync uses **Convergent Encryption**, allowing the server to deduplicate identical save files across different devices and users without having access to the encryption key.

### Block Encryption Model
1. **IV Derivation**: For every 1MB (or 256KB) block of data, the Initialization Vector (IV) is the **MD5 hash of the plaintext data**.
2. **Deterministic Output**: Because the IV is derived from the content itself, the same plaintext data always results in the same ciphertext.
3. **Hardware Acceleration**: The `CryptoEngine` uses `javax.crypto.Cipher` on Android and a native FFI library on Desktop to leverage hardware-accelerated AES instructions (e.g., AES-NI).

### The MAGIC Header
Every encrypted block is prefixed with a **7-byte Magic Header**:
- **Magic**: `NEOSYNC` (ASCII)
- **IV**: 16 bytes (the MD5 of the block content)
- **Data**: The AES-256-CBC encrypted ciphertext.

## 3. Decryption Flow

1. The `DownloadManager` reads the 7-byte Magic Header.
2. It validates the header against `NEOSYNC`.
3. It extracts the 16-byte IV.
4. It initializes a `Cipher` object in `DECRYPT_MODE` with the local Master Key and the extracted IV.
5. It decrypts the remaining block data into the local filesystem.

## 4. Security Considerations

- **Master Key Security**: The LMK never leaves the device.
- **Deduplication vs. Privacy**: Convergent encryption allows for efficient server-side storage (deduplication) while ensuring the server cannot decrypt the content without the user's password.
- **Zero-RAM streaming**: Encryption and decryption happen in 1MB chunks, ensuring the process is performant even on low-resource devices.
