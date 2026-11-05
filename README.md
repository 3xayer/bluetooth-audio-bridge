# Bluetooth Audio Bridge

A macOS menu bar app that turns your Mac into a **Bluetooth speaker for a Fire TV** (or another
Android-based Bluetooth audio source). The Fire TV's audio is received over Bluetooth (A2DP, AAC
codec) and played on any of the Mac's outputs: built-in speakers, a monitor, a USB headset, etc.

macOS can't do this on its own: it only *sends* Bluetooth audio. This app implements the receiving
side itself.

## How it works

1. **Pairing (one time).** Fire TV's "Add Bluetooth device" list hides computers, so a tiny helper app
   on the Fire TV (installed over ADB) starts the pairing with the Mac.
2. **Connecting.** The Mac connects to the Fire TV and opens the A2DP audio channels itself
   (AVDTP over L2CAP), the same way headphones reconnect to a phone. The Fire TV then treats the Mac
   like a pair of Bluetooth headphones and routes its audio there.
3. **Audio.** The stream is AAC (LATM inside RTP). It's decoded with macOS's own AAC decoder and played
   through an adaptive jitter buffer. Playback speed is nudged by up to ±1–2% to absorb bursts and
   clock drift without dropouts.
4. **Lip sync.** The Mac reports its real playback delay to the Fire TV (AVDTP delay reporting), so
   apps shift video to match.

## Setup

### 1. Pair the Fire TV with the Mac (once)

On the Fire TV: **Settings → My Fire TV → Developer options → ADB debugging: ON**
(if Developer options is missing: *About* → click the device name 7×). Note the IP address under
*About → Network*.

On the Mac (needs `adb`, e.g. `brew install android-platform-tools`, plus the Android SDK platform 30
and build-tools to build the helper the first time):

```bash
firetv-helper/pair.sh <fire-tv-ip>
```

Accept "Allow USB debugging" on the TV, then confirm the pairing code on **both** TV and Mac.
Afterwards you can turn ADB debugging off again.

### 2. Build and install the app

```bash
app/make-signing-cert.sh   # once per Mac: local self-signed code-signing identity
app/build.sh install
```

This builds `Bluetooth Audio Bridge.app`, signs it, copies it to `/Applications` and starts it. On
first launch, allow Bluetooth access when macOS asks. With the local signing identity, rebuilds keep
the same code identity, so macOS doesn't ask again and the login item keeps working.

Unit tests (AVDTP message splitting, the jitter buffer/resampler, and the LATM parser):

```bash
app/tests/run.sh
```

## Using it

The menu bar icon shows the state: 🔈 connecting/not connected · hi-fi speaker = connected ·
filled = playing.

| Menu item | What it does |
|---|---|
| **Receive Audio** | On: stay connected and reconnect automatically. Off: disconnect, and the Fire TV goes back to its normal audio output (TV speakers/HDMI). |
| **Reconnect Now** | Drop and re-establish the connection. |
| **Volume** | Volume of the received audio (independent of the Mac's system volume). |
| **Source** | Which paired device to receive from (defaults to the first "Fire TV"). |
| **Output** | Where to play: System Default or a specific device. Can be switched while playing. |
| **Open at Login** | Start automatically (works best with the app in /Applications). |
| **Show Log** | `~/Library/Logs/Bluetooth Audio Bridge.log` |

While the app is connected, the Fire TV sends audio **only** to the Mac. Turn **Receive Audio** off
to hear the TV again.

## Good to know

- **Quality:** AAC LC 44.1 kHz stereo at about 225 kbit/s. The Fire TV caps AAC frames to the
  Bluetooth packet size macOS uses (672 bytes). LDAC isn't possible because no decoder exists.
- **Latency:** Each stream starts with a 200 ms buffer, which shrinks to 120 ms while the link is clean
  and grows (up to 300 ms) after dropouts. Total delay is about 160–300 ms. It's compensated for video
  via delay reports.
- **Remote volume:** The Fire TV remote's volume buttons work. The Fire TV scales the audio itself,
  because macOS doesn't offer AVRCP absolute volume to it. The app's Volume slider is separate.
- **Radio interference:** The Mac shares one radio between Wi-Fi, AirDrop/Continuity and Bluetooth.
  Active AirDrop transfers can cause brief stutters. After any stall the app catches up immediately
  instead of staying behind.
- **Fragility:** The app uses **private macOS Bluetooth APIs** (`CBClassicPeer`), because the
  public ones can't open these channels any more. A future macOS update may break it.
- **Reconnects:** Reconnects automatically after the connection drops and after the Mac wakes from
  sleep. When the Fire TV is off, it retries with backoff (up to once a minute).

## Project layout

```
app/            The menu bar app (Objective-C, built with clang; no Xcode project needed)
  src/SinkSession.m   A2DP sink: AVDTP signaling, media channel, delay reports
  src/AACPlayer.m     AAC decode (AudioToolbox) + adaptive jitter buffer + output
  src/latm.c          LATM/LOAS parser for A2DP AAC payloads
  src/AppDelegate.m   Menu bar UI, settings, reconnect logic
firetv-helper/  Android helper app + pair.sh (one-time pairing over ADB)
probe/          Development/diagnostic tool used while building this (scan, caps, raw capture, decode tests)
```
