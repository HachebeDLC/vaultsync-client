# Implementation Plan: Real-Time Background Auto-Sync

## Phase 1: Background Infrastructure [checkpoint: 8e771d3]
- [x] Task: Set up `Workmanager` Periodic Task [21886e4]
    - [x] Configure a background worker to run every 15-30 minutes.
    - [x] Ensure the worker can access `SharedPreferences` for system paths and auth tokens.
- [x] Task: UI Settings Toggle [2756724]
    - [x] Add an "Enable Auto-Sync" switch in the Settings screen.
    - [x] Handle registration/cancellation of the worker based on the toggle.
- [x] Task: Surgical Switch Save Logic and Profile Merging [7e609ed]
    - [x] Flatten cloud paths to `switch/<TITLE_ID>/`.
    - [x] Implement SAF-robust recursive scanning in Kotlin.
    - [x] Automatically detect and restore to the primary User ID profile.

## Phase 2: Efficient Scanning
- [ ] Task: Implement "Metadata-Only" Diff
    - [ ] Create a fast-path in the sync logic that only triggers network/hash checks if `lastModified` or `size` has changed.
- [ ] Task: Background Auth Handling
    - [ ] Ensure the worker can handle token refresh or re-authentication if necessary.

## Phase 3: Validation and QoL
- [ ] Task: Background Notifications
    - [ ] Show a subtle notification when a background sync starts/completes.
- [ ] Task: Verification
    - [ ] Verify sync consistency by modifying a file and waiting for the background trigger.
- [ ] Task: Conductor - User Manual Verification 'Real-Time Background Auto-Sync'
