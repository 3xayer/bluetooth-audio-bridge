# Bluetooth Audio Bridge

A macOS menu bar app that turns your Mac into a **Bluetooth speaker for a Fire TV, an Android phone**
or another Bluetooth audio source. The audio arrives over Bluetooth (A2DP, AAC or optionally SBC) and
plays on any of the Mac's outputs: built-in speakers, a monitor, a USB headset, etc.

macOS can't do this on its own: it only *sends* Bluetooth audio. This app implements the receiving
side itself.

Tested on macOS 27 (Apple silicon) with a Fire TV Stick 4K Max and a Pixel 8 Pro. Building needs only
clang (Xcode Command Line Tools), no Xcode project.

## How it works

1. **Connecting.** The Mac connects to the paired source and opens the A2DP audio channels itself
   (AVDTP over L2CAP), the same way headphones reconnect to a phone. The source then treats the Mac
   like Bluetooth headphones and routes its audio there.
2. **Audio.** AAC (LATM inside RTP) is decoded with macOS's own decoder, SBC with Android's. Playback
   runs through an adaptive jitter buffer, and its speed is nudged by up to ±1–2% to absorb bursts and
   clock drift without dropouts.
3. **Lip sync.** The Mac reports its real playback delay to the source (AVDTP delay reporting), so
   video apps shift the picture to match.
4. **Remote control.** The app also opens the AVRCP channel itself: play, pause and skip from the menu
   or the Mac's media keys, the current title in the menu and in Now Playing, and absolute volume.

## Setup

### 1. Build and install the app

```bash
app/make-signing-cert.sh   # once per Mac: local self-signed code-signing identity
app/build.sh install
```

This builds the app, signs it, copies it to `/Applications` and starts it. On first launch, allow
Bluetooth access. The local signing identity keeps that permission across rebuilds.

### 2. Pair your source with the Mac (once)

**Fire TV.** Its "Add Bluetooth device" list hides computers, so a small helper app on the Fire TV
starts the pairing. On the Fire TV: **Settings → My Fire TV → Developer options → ADB debugging: ON**
(if Developer options is missing: *About* → click the device name 7×), and note the IP address under
*About → Network*. Then on the Mac (needs `adb`, e.g. `brew install android-platform-tools`, plus the
Android SDK platform 30 and build-tools to build the helper the first time):

```bash
firetv-helper/pair.sh <fire-tv-ip>
```

Accept "Allow USB debugging" on the TV, then confirm the pairing code on **both** TV and Mac.
Afterwards you can turn ADB debugging off again.

**Phones and other devices.** Pair from the device: **Bluetooth → Pair new device**, pick the Mac (it
shows up as a computer) and confirm the code on both sides.

### 3. Pick it in the menu

Choose the device under **Connect To**. Tick it under **Connect Automatically** if the app should
connect to it on its own (a Fire TV that was already paired when the app first started is ticked for
you). Leave phones unticked, so the app doesn't take a phone's audio away from your headphones.

## Using it

| Menu item | What it does |
|---|---|
| **Now playing** | Title and artist from the source's player, with Previous / Play-Pause / Next. The Mac's media keys do the same. |
| **Volume** | The Mac's output volume, in step with the source's volume buttons (absolute volume). Outputs without a volume control (some HDMI/DisplayPort) scale the received audio instead. |
| **Receive Audio** | Off: disconnect, and the source goes back to its own output (TV speakers, phone speaker). |
| **Connect To** | Connect to a paired source now; click it again to disconnect. A disconnected device stays disconnected until you pick it again. |
| **Connect Automatically** | Devices the app connects and reconnects to on its own. |
| **Allow SBC** | For devices without AAC. Off by default; AAC is always preferred. |
| **Show Log** | `~/Library/Logs/Bluetooth Audio Bridge.log` |

## Good to know

- **Quality:** AAC LC stereo at about 225 kbit/s (44.1 kHz), or about 245 kbit/s at 48 kHz when a source
  offers it. Sources cap AAC frames to the Bluetooth packet size macOS uses (672 bytes). SBC, if
  allowed, runs at the source's best setting (about 330 kbit/s on Android). LDAC can't start: Sony's
  encoder needs at least 679-byte packets (open decoders do exist).
- **Latency:** Each stream starts with a 200 ms buffer, which shrinks to 120 ms while the link is clean
  and grows up to 300 ms after dropouts. Total delay is about 160–300 ms, compensated for video via
  delay reports.
- **Radio priority:** The Mac's Bluetooth chip also runs BLE scans and device searches. The biggest:
  with AirPods set to switch automatically, macOS scans 30 ms out of every 40 ms for ~15 s each time
  you use the Mac after a short break, and without priority the source's audio only gets ~60%
  through. So while connected, the app marks the link as a high-priority stream (private bluetoothd
  message); in tests, these scans and device searches then no longer cause dropouts. Waking the
  screen can still cause a ~2 s hiccup, and AirDrop transfers brief stutters. To turn the priority
  off: `defaults write local.bluetooth-audio-bridge linkPriority -bool NO`.
- **Lower bit rate (optional):** `defaults write local.bluetooth-audio-bridge aacBitrate -int 128`
  leaves more headroom for radio interference at some cost in sound quality. Delete the key to go
  back to the maximum.
- **Diagnostics:** `defaults write local.bluetooth-audio-bridge perSecondStats -bool YES` logs the
  received rate every second. `probe/stall-test.py` uses it to fire single system events (BLE scan,
  device search, Wi-Fi scan, CPU/disk/network load, ...) and reports which ones cause stalls.
- **Fragility:** The app relies on **private macOS Bluetooth APIs** (`CBClassicPeer`, bluetoothd
  messages), because the public ones can't open these channels any more. A future macOS update may
  break it.

## Project layout

```
app/                  The menu bar app (Objective-C)
  src/SinkSession.m   A2DP sink: AVDTP signaling, codec choice (AAC/SBC), media channel, delay reports
  src/AACPlayer.m     AAC decoding (AudioToolbox), adaptive jitter buffer, output
  src/latm.c          LATM/LOAS parser for A2DP AAC payloads
  src/AVRCP.m         Remote control: play/pause/skip, titles, absolute volume
  src/LinkPriority.m  Radio priority for the audio link
  src/AppDelegate.m   Menu bar UI, settings, reconnect logic
  src/MenuViews.m     Menu rows, player card and volume slider
  src/SystemVolume.m  The Mac's output volume
  third_party/sbc/    Android's SBC decoder
  tests/run.sh        Unit tests (AVDTP message splitting, jitter buffer/resampler, LATM parser)
firetv-helper/        Android helper app + pair.sh (one-time Fire TV pairing over ADB)
probe/                Development and diagnostic tool (scan, caps, raw capture, decode and stall tests)
```

## License

MIT, see [LICENSE](LICENSE). The SBC decoder in `app/third_party/sbc` is Android's, under the Apache
License 2.0 (see its [LICENSE](app/third_party/sbc/LICENSE)).
