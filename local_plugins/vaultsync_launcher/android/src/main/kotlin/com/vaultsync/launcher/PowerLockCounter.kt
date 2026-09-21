package com.vaultsync.launcher

/**
 * Pure reference-counting logic for the process-wide power lock, kept free of
 * Android imports so it can be unit tested without a device/emulator.
 *
 * Safe under concurrent access: all mutation happens inside a `synchronized`
 * block on the counter's own monitor.
 */
class PowerLockCounter {
    private var refCount = 0

    val count: Int
        @Synchronized get() = refCount

    /**
     * Increments the shared count.
     * @return true if this call caused the 0 -> 1 transition (i.e. the caller
     *         is responsible for actually acquiring the underlying resource).
     */
    @Synchronized
    fun acquire(): Boolean {
        refCount++
        return refCount == 1
    }

    /**
     * Decrements the shared count.
     * @return true if this call caused the 1 -> 0 transition (i.e. the caller
     *         is responsible for actually releasing the underlying resource).
     *         Returns false and leaves the count untouched if it was already
     *         at zero (defensive against unbalanced release calls).
     */
    @Synchronized
    fun release(): Boolean {
        if (refCount <= 0) {
            return false
        }
        refCount--
        return refCount == 0
    }
}
