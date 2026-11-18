# Remote Control Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a foreground HTTP remote control service with a login web page and authenticated control APIs.

**Architecture:** Android/Kotlin owns the foreground service, HTTP server, session handling, and remote actions. Flutter/Dart owns settings UI and platform-channel configuration save calls. Existing SharedPreferences config remains the source of truth.

**Tech Stack:** Flutter Material UI, MethodChannel, Android foreground service, Kotlin `ServerSocket`, Android `SharedPreferences`, existing SMS/call APIs.

---

### Task 1: Flutter Model And Settings UI

**Files:**
- Modify: `lib/models/app_models.dart`
- Modify: `lib/app.dart`
- Modify: `lib/pages/settings_page.dart`
- Test: `test/widget_test.dart`

- [ ] Add `RemoteControlConfig` to parse `config.remoteControl`.
- [ ] Pass `AppConfig` into `SettingsPage`.
- [ ] Add a settings card for enable, port, password, and save.
- [ ] Verify widget test fails before implementation and passes after implementation.

### Task 2: Android Shared Store And Remote Actions

**Files:**
- Create: `android/app/src/main/kotlin/me/stackli/doppel/RemoteControlStore.kt`
- Modify: `android/app/src/main/kotlin/me/stackli/doppel/SmsPipeline.kt`
- Modify: `android/app/src/main/kotlin/me/stackli/doppel/MainActivity.kt`

- [ ] Centralize remote config reading and config merging.
- [ ] Add remote SMS send and call start entrypoints that reuse current permissions/config.
- [ ] Sync the remote service after app startup and config saves.

### Task 3: Foreground HTTP Service

**Files:**
- Create: `android/app/src/main/kotlin/me/stackli/doppel/RemoteControlService.kt`
- Create: `android/app/src/main/kotlin/me/stackli/doppel/RemoteHttpServer.kt`
- Modify: `android/app/src/main/AndroidManifest.xml`

- [ ] Add foreground service permissions and manifest service entry.
- [ ] Implement `RemoteControlService` notification, start, stop, and server lifecycle.
- [ ] Implement HTTP parsing, session login, static web console, and JSON APIs.

### Task 4: Verification

**Files:**
- Verify all modified files.

- [ ] Run `/Users/liqiao/sdk/flutter/bin/flutter analyze`.
- [ ] Run `/Users/liqiao/sdk/flutter/bin/flutter test test/widget_test.dart`.
- [ ] Run `/Users/liqiao/sdk/flutter/bin/flutter build apk --debug`.
- [ ] Report exact verification results and any residual risk.
