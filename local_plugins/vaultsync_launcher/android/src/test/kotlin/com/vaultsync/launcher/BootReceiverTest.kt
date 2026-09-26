package com.vaultsync.launcher

import android.content.Intent
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class BootReceiverTest {

    @Test
    fun `boot completed action starts the service`() {
        assertTrue(BootReceiver.shouldStartService(Intent.ACTION_BOOT_COMPLETED))
    }

    @Test
    fun `my package replaced action starts the service`() {
        assertTrue(BootReceiver.shouldStartService(Intent.ACTION_MY_PACKAGE_REPLACED))
    }

    @Test
    fun `null action does not start the service`() {
        assertFalse(BootReceiver.shouldStartService(null))
    }

    @Test
    fun `unrelated action does not start the service`() {
        assertFalse(BootReceiver.shouldStartService(Intent.ACTION_SCREEN_ON))
    }

    @Test
    fun `an external package's replaced action does not start the service`() {
        // ACTION_PACKAGE_REPLACED (with a data URI for the affected package)
        // is a different, separately-restricted broadcast from
        // ACTION_MY_PACKAGE_REPLACED (sent only to the app being replaced
        // itself) and must not be treated the same way here.
        assertFalse(BootReceiver.shouldStartService(Intent.ACTION_PACKAGE_REPLACED))
    }
}
