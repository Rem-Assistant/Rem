#!/usr/bin/env bash
# Launch -> first-run walkthrough of the Android debug APK on the booted emulator.
# Invoked as a SINGLE line from .github/workflows/android-preview.yml because the
# emulator-runner action executes each `script` LINE in its own `sh -c` — which
# breaks multi-line shell (for-loops, backgrounded screenrecord + wait) and drops
# per-line variables. Running one script file keeps the whole thing in one shell.
set -x

APP=com.remapp.rem.debug

adb wait-for-device
adb install -r android/app/build/outputs/apk/debug/app-debug.apk

# Pre-grant runtime permissions so first-run isn't blocked on system dialogs.
for P in android.permission.READ_CALENDAR android.permission.RECORD_AUDIO android.permission.POST_NOTIFICATIONS; do
  adb shell pm grant "$APP" "$P" || true
done

# Launch the app; fall back to the launcher intent if the explicit activity moves.
adb shell am start -n "$APP/com.remapp.rem.MainActivity" \
  || adb shell monkey -p "$APP" -c android.intent.category.LAUNCHER 1
sleep 6

# Record ~24s while driving a short launch -> first-run / sign-in walkthrough.
adb shell screenrecord --time-limit 24 --bit-rate 6000000 /sdcard/preview.mp4 &
REC=$!
sleep 3;  adb shell input tap 540 1900
sleep 3;  adb shell input swipe 540 1400 540 700 300
sleep 3;  adb shell input tap 540 1900
sleep 3;  adb shell input keyevent 4
wait "$REC" || true

adb pull /sdcard/preview.mp4 preview.mp4 || true
