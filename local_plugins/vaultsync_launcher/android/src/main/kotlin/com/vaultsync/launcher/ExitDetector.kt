package com.vaultsync.launcher

/**
 * Type of a usage-event transition relevant to detecting emulator exits.
 *
 * Android's UsageEvents.Event has many more event types (configuration
 * changes, screen state, etc.) that we intentionally ignore — the caller
 * (AutomationEngine) maps only MOVE_TO_FOREGROUND / MOVE_TO_BACKGROUND into
 * this enum before handing events to [ExitDetector], which keeps this class
 * free of any Android dependency and testable with plain JUnit.
 */
enum class UsageEventType {
    FOREGROUND,
    BACKGROUND
}

/** A single (package, transition, when) usage event. */
data class UsageEvent(
    val packageName: String,
    val eventType: UsageEventType,
    val timestampMs: Long
)

/**
 * Pure logic for turning a chronological stream of foreground/background
 * transitions into "this package exited at this time" facts.
 */
object ExitDetector {

    /**
     * For each package in [monitoredPackages] that appears in [events],
     * returns the timestamp of its exit: the last BACKGROUND event for that
     * package that is not followed by a later FOREGROUND event for the same
     * package.
     *
     * A package whose most recent event in [events] is FOREGROUND — i.e. it
     * is still in the foreground, or was closed and reopened within the
     * window — is not reported as an exit.
     *
     * [events] must already be in chronological order (oldest first).
     */
    fun findExits(
        events: List<UsageEvent>,
        monitoredPackages: Set<String>
    ): Map<String, Long> {
        val lastEventType = HashMap<String, UsageEventType>()
        val lastBackgroundAt = HashMap<String, Long>()

        for (event in events) {
            if (event.packageName !in monitoredPackages) continue
            lastEventType[event.packageName] = event.eventType
            if (event.eventType == UsageEventType.BACKGROUND) {
                lastBackgroundAt[event.packageName] = event.timestampMs
            }
        }

        val exits = LinkedHashMap<String, Long>()
        for ((pkg, type) in lastEventType) {
            if (type == UsageEventType.BACKGROUND) {
                exits[pkg] = lastBackgroundAt.getValue(pkg)
            }
        }
        return exits
    }
}
