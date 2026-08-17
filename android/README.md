# Rem Android

Early native Android client for Rem. **Not on Google Play** and not at iPhone parity.

Package id matches iOS: `com.remapp.rem`  
Debug builds use `com.remapp.rem.debug`.

Current dogfood version: **0.8.3**.

## What you need

- macOS, Linux, or Windows
- [Android Studio](https://developer.android.com/studio) (this ships the JDK Rem’s Gradle setup expects)
- Android SDK **26+** (compile/target SDK **36**)
- A phone or emulator with **USB or wireless debugging**

You do **not** need to install Gradle yourself. Use the wrapper in this folder (`./gradlew`).

## Build and install

1. Copy `local.properties.example` to `local.properties`.
2. Set `sdk.dir` to your Android SDK, or open the project in Android Studio and let it write that line.
3. Optionally set backend URLs and the Google **web** client id in `local.properties` (see the example file). Without those, the app still **builds**, but it cannot talk to Rem’s hosted backend — same idea as a clean iOS clone.
4. Connect a device (`adb devices` should list it).
5. From this folder:

```bash
export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"   # macOS
export ANDROID_HOME="$HOME/Library/Android/sdk"
./gradlew :app:installDebug
```

Or: Android Studio → open `android/` → Run.

Wireless debugging:

```bash
adb connect <phone-ip>:<port>
./gradlew :app:installDebug
```

## Staging vs Production

After sign-in, **Settings** has a Staging / Production switch. Changing it signs you out and points the app at the other backend. Defaults (once you set URLs in `local.properties`):

| Switch | Meaning |
|--------|---------|
| Staging | Rem’s staging API |
| Production | Rem’s production API |

Leave it on **Staging** unless you mean to hit production.

## Sign-in

- **Continue with this device** works for local dogfood. Use that if Google is blocked.
- **Continue with Google** uses the same **web** OAuth client id as the backend (`GOOGLE_CLIENT_ID`). Google *also* needs an **Android** OAuth client in that Cloud project:

| Field | Debug | Release |
|-------|--------|---------|
| Package name | `com.remapp.rem.debug` | `com.remapp.rem` |
| SHA-1 | *your* debug keystore | *your* release keystore |

Print the debug SHA-1 for this machine:

```bash
./gradlew :app:signingReport
```

Look at the **debug** variant. Until that Android OAuth client exists, Google often shows “No credentials available”. That is a Cloud Console setup issue, not a Rem password problem.

## What works today

- Staging / Production switch
- Device sign-in (Google is optional and often blocked without the Android OAuth client)
- Agenda: day pager (today / previous / next), daily brief on **today only**, device calendar overlay, tasks for that day
- Inbox: count, empty copy, add task
- Task detail: title / priority / status, delete, start a focus session
- Chat (OpenClaw operator WebSocket), session picker, empty-state starters
- Speak mode (mic → same chat; ElevenLabs if the gateway has a key, else system TTS)
- Settings: connectors, channels, memory, models, capabilities, connections, billing **read-only**, about / share / feedback / bug report
- First-run permissions (calendar, mic, notifications)

## What this client does not do yet

- Not Play-ready (no Play Billing purchases; usage/plan is read from the Rem backend only)
- Not a full iPhone copy (layout, grouping, Live Activities, Allowed Apps, share-into-Rem, etc.)
- **Add a task** from Agenda still creates an **Inbox** item (no date). It does not place the task on the day you are viewing
- Tapping the Agenda date jumps to **today**; it does not open a month calendar picker
- Debug SHA-1 is per machine — do not reuse someone else’s fingerprint in Google Cloud

## Brand assets

Launcher and in-app logo are copied from the iOS source of truth:

`RemClaw/Assets.xcassets/AppIcon.appiconset/Logo.png`

## Xiaomi / MIUI notes

- If Speak stops after the screen locks: **Apps → Rem → Battery → No restrictions**, and Autostart.
- If notifications never appear: also allow Rem under **Apps → Rem → Notifications** (the runtime prompt is sometimes not enough).
