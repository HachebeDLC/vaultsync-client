package com.vaultsync.launcher

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Covers the HTTP-status gate that must run before any download is written to
 * disk or handed to the decryptor (see DownloadManager.handleDownloadFile).
 *
 * Background: a stale token captured just before a concurrent token refresh
 * produced a 401 from `/api/v1/download`. Its JSON error body was streamed
 * into the decryptor, which failed deep inside javax.crypto with
 * WRONG_FINAL_BLOCK_LENGTH — a confusing symptom for "this download was never
 * authorized". [isSuccessfulDownloadStatus] is the single place that decides
 * whether a response is safe to write; run with:
 * ./gradlew :vaultsync_launcher:testDebugUnitTest
 */
class DownloadStatusTest {

    @Test
    fun `200 is successful`() {
        assertTrue(isSuccessfulDownloadStatus(200))
    }

    @Test
    fun `401 is rejected`() {
        assertFalse(isSuccessfulDownloadStatus(401))
    }

    @Test
    fun `403 is rejected`() {
        assertFalse(isSuccessfulDownloadStatus(403))
    }

    @Test
    fun `404 is rejected`() {
        assertFalse(isSuccessfulDownloadStatus(404))
    }

    @Test
    fun `500 is rejected`() {
        assertFalse(isSuccessfulDownloadStatus(500))
    }

    @Test
    fun `206 is rejected when the request was not a range request`() {
        assertFalse(isSuccessfulDownloadStatus(206, isRangeRequest = false))
    }

    @Test
    fun `206 is successful only when the request was a range request`() {
        assertTrue(isSuccessfulDownloadStatus(206, isRangeRequest = true))
    }

    @Test
    fun `401 message is distinguishable and carries the literal HTTP 401 substring`() {
        val message = describeDownloadHttpFailure(401)
        assertEquals("Download failed: HTTP 401 Unauthorized", message)
        assertTrue(
            "Dart's SyncNetworkService classifies failures via `contains('HTTP 401')`; " +
                "the message must keep that literal substring",
            message.contains("HTTP 401")
        )
    }

    @Test
    fun `403 message is distinguishable`() {
        assertEquals("Download failed: HTTP 403 Forbidden", describeDownloadHttpFailure(403))
    }

    @Test
    fun `404 message keeps the literal HTTP 404 substring other failure paths already log`() {
        val message = describeDownloadHttpFailure(404)
        assertEquals("Download failed: HTTP 404 Not Found", message)
        assertTrue(message.contains("HTTP 404"))
    }

    @Test
    fun `unrecognized codes still produce a clear generic message`() {
        assertEquals("Download failed: HTTP 418", describeDownloadHttpFailure(418))
    }
}
