# Bluetooth Audio Bridge

A macOS menu bar app that turns your Mac into a **Bluetooth speaker for a Fire TV, an Android phone**
or another Bluetooth audio source. The audio is received over Bluetooth (A2DP, AAC or optionally
SBC) and played on any of the Mac's outputs: built-in speakers, a monitor, a USB headset, etc.

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
5. **Remote control.** The app also opens the AVRCP channel itself: the menu and the Mac's media keys
   play, pause and skip on the source, the current title shows in the menu and in Control Center's
   Now Playing, and a source that uses absolute volume (the Fire TV does) changes the Mac's volume
   with its own volume buttons (and follows the Mac's volume keys).

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

### Phones and other devices

Pair from the phone: **Bluetooth → Pair new device**, pick the Mac (it shows up as a computer) and
confirm the code on both sides. The ADB helper is only needed for the Fire TV, whose list hides
computers. Then choose the phone under **Connect To** in the app's menu.

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
| **Now playing** | Title and artist from the source's player, with Previous / Play-Pause / Next buttons. The Mac's media keys do the same. |
| **Receive Audio** | On: connect and reconnect. Off: disconnect, and the source goes back to its normal audio output (TV speakers/HDMI, phone speaker). |
| **Reconnect Now** | Drop and re-establish the connection. |
| **Volume** | The Mac's output volume, kept in step with the source's volume buttons (absolute volume). If the output device has no volume control (some HDMI/DisplayPort outputs), it scales the received audio instead. |
| **Connect To** | Connect to this paired audio source now (a spinner shows while it connects); click it again to disconnect. A disconnected device isn't reconnected automatically until you pick it again. A device picked here gets a few tries if it isn't reachable, then the automatic devices take over again. |
| **Connect Automatically** | Devices the app connects to on its own and reconnects to (by default the Fire TV). Leave phones off, so the app doesn't take a phone's audio away from your headphones whenever it's in range. |
| **Allow SBC** | For devices that don't offer AAC. Off by default; AAC is always preferred. |
| **Output** | Where to play: System Default or a specific device. Can be switched while playing. |
| **Open at Login** | Start automatically (works best with the app in /Applications). |
| **Show Log** | `~/Library/Logs/Bluetooth Audio Bridge.log` |

While the app is connected, the source sends audio **only** to the Mac. Turn **Receive Audio** off
to hear the TV again.

## Good to know

- **Quality:** AAC LC stereo at about 225 kbit/s (44.1 kHz, Fire TV) or 245 kbit/s (48 kHz, used when
  the source offers it, as phones do). Sources cap AAC frames to the Bluetooth packet size macOS uses
  (672 bytes). SBC, if allowed, runs at the source's best setting (about 330 kbit/s on Android).
  LDAC isn't expected to start: Sony's encoder needs at least 679 bytes (open decoders do exist).
- **Latency:** Each stream starts with a 200 ms buffer, which shrinks to 120 ms while the link is clean
  and grows (up to 300 ms) after dropouts. Total delay is about 160–300 ms. It's compensated for video
  via delay reports.
- **Remote volume:** Through the app's own AVRCP channel the Fire TV uses absolute volume: its remote
  changes the Mac's volume, and the Mac's volume keys move the Fire TV's level. Sources that don't
  support it scale the audio themselves instead.
- **Radio priority:** The Mac's Bluetooth chip also runs BLE scans and device searches. The biggest
  one: with AirPods set to switch automatically, macOS scans 30 ms out of every 40 ms for ~15 s each
  time you use the Mac after a short break. Without priority, the Fire TV's audio then gets only
  ~60% through and drops out. The app therefore marks the Fire TV link as a high-priority stream
  while it's connected (private bluetoothd message). In tests, the 75% scan and back-to-back device
  searches then no longer cause dropouts. Waking the screen from sleep can still cause a ~2 s
  hiccup. To turn it off: `defaults write local.bluetooth-audio-bridge linkPriority -bool NO`.
  Active AirDrop transfers can cause brief stutters too. After any stall the app catches up
  immediately instead of staying behind.
- **Lower bit rate (optional):** `defaults write local.bluetooth-audio-bridge aacBitrate -int 128`
  asks the Fire TV for 128 kbit/s AAC, which leaves more headroom for radio interference at some cost
  in sound quality. Remove the key to go back to the maximum.
- **Diagnostics:** `defaults write local.bluetooth-audio-bridge perSecondStats -bool YES` logs the
  received rate every second. `probe/stall-test.py` uses it to fire individual system events
  (BLE scan, device search, Wi-Fi scan, CPU/disk/network load, ...) and report which ones cause stalls.
- **Fragility:** The app uses **private macOS Bluetooth APIs** (`CBClassicPeer`), because the
  public ones can't open these channels any more. A future macOS update may break it.
- **Reconnects:** Reconnects after the connection drops and after the Mac wakes from sleep. With
  several automatic devices it takes turns; when none is reachable, it retries with backoff (up to
  once a minute).

## Project layout

```
app/            The menu bar app (Objective-C, built with clang; no Xcode project needed)
  src/SinkSession.m   A2DP sink: AVDTP signaling, codec choice (AAC/SBC), media channel, delay reports
  src/AACPlayer.m     AAC decode (AudioToolbox) + adaptive jitter buffer + output
  src/AVRCP.m         Remote control: play/pause/skip, titles, absolute volume
  src/LinkPriority.m  Radio priority for the audio link
  third_party/sbc/    Android's SBC decoder (Apache-2.0)
  src/latm.c          LATM/LOAS parser for A2DP AAC payloads
  src/AppDelegate.m   Menu bar UI, settings, reconnect logic
firetv-helper/  Android helper app + pair.sh (one-time pairing over ADB)
probe/          Development/diagnostic tool used while building this (scan, caps, raw capture, decode tests)
```

## License

MIT, see [LICENSE](LICENSE). The SBC decoder in `app/third_party/sbc` is Android's, under the Apache
License 2.0 (see its [LICENSE](app/third_party/sbc/LICENSE)).

This is a hobby project and not affiliated with Amazon, Apple, Google or Sony. Fire TV, AirPods,
Pixel and LDAC are trademarks of their owners.
