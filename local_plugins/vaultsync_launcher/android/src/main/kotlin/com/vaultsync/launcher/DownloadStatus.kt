package com.vaultsync.launcher

/**
 * Pure, testable status-check for download responses.
 *
 * Extracted from [DownloadManager.handleDownloadFile] so the "reject anything
 * that isn't a real success" rule can be unit-tested with plain JUnit (no
 * Android/OkHttp deps) — see DownloadStatusTest.
 *
 * Background: a stale token captured just before a concurrent token refresh
 * produced a 401 from `/api/v1/download`. The response body for a 401 is a
 * small JSON error object, not ciphertext — if that body is ever handed to
 * the decryptor, AES-CBC fails with WRONG_FINAL_BLOCK_LENGTH deep inside
 * javax.crypto, which is a confusing symptom for what is really just "this
 * download was never authorized". The fix is to always check the HTTP status
 * BEFORE touching the target file or the decryptor, for every branch
 * (Shizuku, SAF, and plain filesystem; full and patch downloads alike).
 */
internal fun isSuccessfulDownloadStatus(code: Int, isRangeRequest: Boolean = false): Boolean {
    return code == 200 || (isRangeRequest && code == 206)
}

/**
 * Produces a clear, human-readable failure message for a non-successful
 * download response. Deliberately keeps the literal substring "HTTP <code>"
 * so callers on the Dart side (SyncNetworkService._executeNative /
 * _mapNativeError) can keep classifying failures with a simple
 * `contains('HTTP 401')` check without depending on wording changes here.
 */
internal fun describeDownloadHttpFailure(code: Int): String {
    val reason = when (code) {
        401 -> "Unauthorized"
        403 -> "Forbidden"
        404 -> "Not Found"
        409 -> "Conflict"
        500 -> "Internal Server Error"
        502 -> "Bad Gateway"
        503 -> "Service Unavailable"
        else -> null
    }
    return if (reason != null) "Download failed: HTTP $code $reason" else "Download failed: HTTP $code"
}
