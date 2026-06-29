# NorthStar iOS — Implementation Plan

**A production-grade iOS port of the Android Tripper-dash app** — low-power navigation projected onto the Royal Enfield **Tripper TFT dash** with the phone screen **off**. Targets the **Himalayan 450** and **Guerrilla 450** (both use the same round 4″ Tripper dash).

> **Base the port on [OpenDash](https://github.com/subtlesayak/open-dash), not NorthStar.** OpenDash is NorthStar's successor — **identical dash link** (same `K1GPacket`/`DashSocket`/UDP `192.168.1.x`/`RE_*` discovery, fw 11.63) but a **superset of features**: vehicle profiles, expenses tracking, PUC/insurance reminders, media/caller cards, and the **idle dash wallpaper** feature. Everything in this plan's dash-link sections is unchanged; OpenDash just adds more on top of the same protocol.

- **Distribution:** TestFlight / personal signing (paid Apple Developer Program)
- **Hardware:** validated on a real bike as we build (owner has the bike)
- **Reference:** the OpenDash Android Kotlin app + the `better-dash` protocol notes. The K1G packet layouts below are ported verbatim from the validated Android implementation (fw 11.63).

> ⚠️ Independent, community project — not affiliated with Royal Enfield. Display-only link (video + joystick); never touches the ECU/engine/brakes.

---

## 0. The load-bearing assumptions (validate these FIRST, on the bike)

Everything else is "just engineering." These three are the project's existential risks and Phase 1 exists to retire them in order:

1. **Background-with-screen-off works.** iOS must keep encoding H.264 and pumping UDP for hours after the phone locks. Solution: this is a navigation app → claim the **Location background mode** (`allowsBackgroundLocationUpdates = true`, `Always` authorization). That keeps the process unsuspended; VideoToolbox + sockets keep running. **If this fails, the project fails** — test it on day one with a trivial "log a timestamp every second with screen off for 30 min" build.
2. **Control plane reaches the dash.** The Android app **broadcasts** to `192.168.1.255:2000`. iOS broadcast needs the `com.apple.developer.networking.multicast` entitlement (Apple-approved, paid program). **Test unicast to `192.168.1.1:2000` first** — if the dash answers, we avoid the entitlement entirely. If not, file the entitlement request immediately (multi-day turnaround).
3. **The handshake completes from iOS.** RSA-1024 + AES-256 via the Security framework, byte-identical to the Kotlin path, against your firmware.

---

## 1. Distribution, capabilities & entitlements

| Item | Value | Notes |
|---|---|---|
| Bundle ID | `com.<you>.northstar` | |
| Min iOS | **16.0** | Network.framework maturity, MapLibre, SwiftUI nav stack |
| Signing | Automatic, paid team | TestFlight build → internal/external testers |
| **Background Modes** | `location`, `audio`*, `external-accessory`✗ | `location` is the real keep-alive. `audio` only as a fallback experiment (silent-audio trick) — fragile, avoid if location suffices. |
| **Hotspot Configuration** | `com.apple.developer.networking.HotspotConfiguration` | Free; lets us join the `RE_*` AP via `NEHotspotConfiguration`. |
| **Multicast/Broadcast** | `com.apple.developer.networking.multicast` | **Only if unicast control fails.** Requires Apple's request form. |
| `Info.plist` strings | `NSLocalNetworkUsageDescription`, `NSLocationAlwaysAndWhenInUseUsageDescription`, `NSLocationWhenInUseUsageDescription`, `NSBonjourServices` (if needed) | Local-network consent prompt fires on first UDP to the dash subnet. |

**Why TestFlight, not App Store:** unofficial reverse-engineered protocol + aggressive background networking is review-risky. TestFlight review is lighter and the right home for this. Design assumes it.

---

## 2. Tech stack & dependencies

| Concern | Android | iOS choice |
|---|---|---|
| Language / UI | Kotlin / Compose | **Swift 5.9 / SwiftUI** (+ UIKit bridges where needed) |
| H.264 encode | MediaCodec (HW) | **VideoToolbox** `VTCompressionSession` (HW AVC Baseline) |
| Off-screen draw | Surface + Canvas | **Metal / Core Graphics → `CVPixelBuffer`** pool |
| Map | MapLibre Android | **MapLibre Native iOS** (SPM), keyless OpenFreeMap |
| Routing | OSRM HTTP | same HTTP API (own server later) |
| UDP | `DatagramSocket` | **Network.framework** (`NWConnection`; `NWConnectionGroup` if broadcast) |
| Join WiFi | `WifiNetworkSpecifier` | **`NEHotspotConfiguration(ssidPrefix:)`** |
| RSA/AES | JCE | **Security framework** (RSA-PKCS1) + **CryptoKit/CommonCrypto** (AES-CBC) |
| DB | SQLite | **GRDB.swift** (SPM) |
| Sync | Firebase | **Firebase iOS SDK** (Auth + Firestore) |
| TTS | TextToSpeech | **AVSpeechSynthesizer** |
| GPS | LocationManager | **CoreLocation** |
| Keep-alive | Foreground service | **Background location mode** |
| Media now-playing | NotificationListener | **MPNowPlayingInfoCenter (read is restricted)** — degraded feature |

**SPM packages:** `maplibre-gl-native-distribution`, `GRDB.swift`, `firebase-ios-sdk` (FirebaseAuth, FirebaseFirestore). Everything else is system frameworks.

---

## 3. Project structure

```
NorthStarApp/
├── App/
│   ├── NorthStarApp.swift              // @main, app lifecycle, DI container
│   └── AppEnvironment.swift            // shared services (DI)
├── Dash/                               // ── THE LINK LAYER (port of dash/) ──
│   ├── Protocol/
│   │   ├── K1GPacket.swift             // build/patchSeq/parseIncoming + Tlv
│   │   ├── DashCommands.swift          // every control packet (auth, nav, projection, media)
│   │   └── HexEncoding.swift           // hexToBytes / Data⇄hex
│   ├── DashAuth.swift                  // RSA-1024 + AES-256 handshake state machine
│   ├── DashSocket.swift               // Network.framework: ctrl(2000) / rx(2002) / rtp(5000)
│   ├── DashSession.swift              // orchestration: auth → nav-mode → stream + keep-alives
│   ├── WiFi/
│   │   └── DashWiFiManager.swift       // NEHotspotConfiguration join + reachability
│   └── Video/
│       ├── DashEncoder.swift           // VTCompressionSession (526×300 baseline)
│       ├── NalProcessor.swift          // Annex-B split, SPS/PPS bundling, SEI/AUD drop
│       └── RtpPacketizer.swift         // RFC 6184 FU-A, no STAP-A
├── Map/
│   ├── OffscreenMapRenderer.swift      // MapLibre snapshot/Metal → CVPixelBuffer @ 2–4fps
│   ├── TileProvider.swift              // OpenFreeMap caching
│   └── LocationTracker.swift           // CoreLocation, background updates
├── Nav/
│   ├── Router.swift                    // OSRM client + reroute
│   ├── NavEngine.swift                 // progress, maneuver glyphs, distance-to-turn, ETA
│   └── VoiceManager.swift              // AVSpeechSynthesizer: off/chime/full
├── Data/
│   ├── NorthStarDB.swift               // GRDB schema + DAOs
│   ├── Models/                         // Ride, Maintenance, FuelEntry, Garage…
│   ├── RideRecorder.swift
│   ├── SyncRepository.swift            // Firestore mirror of local SQLite
│   └── DiagnosticsLog.swift            // protocol-capture logging (mirrors RideDiagnostics)
├── Media/
│   └── NowPlayingProvider.swift        // MPNowPlayingInfoCenter (limited)
├── ViewModels/
│   ├── DashViewModel.swift             // the big one: ties session + encoder + map + nav
│   ├── RouteViewModel.swift
│   └── GarageViewModel.swift
├── UI/                                 // SwiftUI screens (port of ui/screens)
│   ├── HomeView, RouteView, DashView, RidesView, GarageView, SettingsView, LoginView
│   ├── Components/ (CircularDashPreview, Joystick, BarChart, NorthStarMap…)
│   └── Theme/
├── Tools/
│   └── DashEmulator/                   // host-side replay of captured K1G packets (dev only)
└── Resources/ (Assets, Info.plist, *.entitlements)
```

---

## 4. The dash link layer (most critical — ported component by component)

### 4.1 `K1GPacket.swift`
Direct port. Big-endian builder with `outer_len` placeholder patched after assembly, `seg_count = 1 + tlvs`, fixed header `00 00 00 00 02 01 00 05` + `"K1G "` + seq byte. `patchSeq` rewrites the byte after the magic and fixes `outer_len`. `parseIncoming` reads segments from **offset 8** (dash→app uses the short header). Use `Data` and `withUnsafeBytes`; no endianness surprises since we write bytes explicitly.

### 4.2 `DashAuth.swift` — the crypto handshake
State machine accumulating `07 00` (modulus) and `07 03` (exponent), possibly across packets. On both present: generate 32 random bytes (`SecRandomCopyBytes`) as the AES-256 session key, build `SSID_utf8 ‖ aesKey`, RSA-encrypt with **PKCS1** padding, emit `authSendKey(ciphertext)` (must be exactly 128 B). `07 01 01` → confirmed; `07 01 !=01` → reset + retry.

iOS RSA from raw modulus+exponent:
```swift
// Reconstruct an RSA public key from modulus (n) and exponent (e) → DER (PKCS#1 RSAPublicKey) → SecKey
let der = ASN1.rsaPublicKey(modulus: nData, exponent: eData)   // small helper, ~30 lines
let key = SecKeyCreateWithData(der as CFData,
            [kSecAttrKeyType: kSecAttrKeyTypeRSA,
             kSecAttrKeyClass: kSecAttrKeyClassPublic] as CFDictionary, nil)!
let cipher = SecKeyCreateEncryptedData(key, .rsaEncryptionPKCS1, payload as CFData, nil)! as Data
// cipher.count must == 128 (RSA-1024)
```
AES-256-CBC telemetry decrypt (`0F`): `IV = first 16 bytes`, CommonCrypto or CryptoKit-free `CCCrypt`.

### 4.3 `DashSocket.swift` — UDP via Network.framework
Three connections, **bound to the dash WiFi interface** (`NWParameters.requiredInterface = dashInterface` — the iOS analogue of Android's `Network.bindSocket`, so packets go over WiFi while cellular stays default):

- **ctrl** → send to `192.168.1.1:2000` (test unicast first) or broadcast `…255:2000` (needs entitlement). `NWConnection(host:port:using:.udp)`.
- **rx** → listen on local `:2002` **opened before the first ctrl send** (catches the early pubkey; avoids ICMP-unreachable confusing the dash). Use an `NWListener` on UDP 2002 or a connection with explicit local endpoint.
- **rtp** → ephemeral, send to `192.168.1.1:5000`.

Patch the rolling seq on every ctrl send. Fire-and-forget; never crash on send error (link drops are normal → session fails & reconnects).

> ⚠️ **iOS gotcha:** binding a UDP socket to a *fixed* local port (2002) and to a specific interface is more awkward with `NWConnection` than BSD sockets. If Network.framework fights us, fall back to **POSIX sockets** (`socket/bind/setsockopt(SO_BROADCAST)/sendto/recvfrom`) on a dedicated GCD queue — fully allowed, and closer to the Android semantics. Decide during Phase 1 spike.

### 4.4 `DashSession.swift` — orchestration
Port the exact sequence:
1. Open sockets (RX first). Start RX loop + 1 Hz status heartbeat.
2. Send **initial burst** (includes `authRequest`, hostname announce, time-sync, the fixed capture packets).
3. RX loop: `07 00/03` → send key; `07 01 01` → confirmed (15 s timeout, 5 retries).
4. `enterNavMode`: navContext → emptyLists → route-card ×4 → projectionFrame → navPlaceholder → `z2` (once) → route-card.
5. On `startStreaming`: projection HB **4 Hz**, route-card keep-alive **1 Hz**, nav-info **1 Hz**, media-info **1 Hz**.
6. RX loop continuously answers: `09 06 55`→`frameDecodedIdr`, `09 04 55`→`frameDecodedP`, `09 00`→buttonAck + UI joystick, decrypt `0F`/log `0C` telemetry.
7. **RX watchdog:** once first IDR acked, >6 s silence ⇒ link lost (UDP gives no error otherwise).

Use Swift `Task`/`async` + an actor for state instead of Kotlin coroutines + `@Volatile`. The `DashSession` is an `actor` to serialize socket access.

### 4.5 Video pipeline (`DashEncoder` + `NalProcessor` + `RtpPacketizer`)
- **DashEncoder:** `VTCompressionSessionCreate` for **526×300, H.264 Baseline, Level 4.1, 1 s keyframe interval, ~200 kbps**, `kVTCompressionPropertyKey_RealTime = true`, request HW (`kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder`). Feed `CVPixelBuffer`s from the map renderer; pull NALs in the output callback. Live bitrate switch (200 k moving / 100 k static) via `VTSessionSetProperty(AverageBitRate)` — no reconfigure (mirrors Android's `requestBitrate`).
- **NalProcessor:** VideoToolbox gives length-prefixed AVCC by default → convert to **Annex-B**; cache SPS(7)/PPS(8); on IDR(5) prepend `00 00 00 01 SPS 00 00 00 01 PPS 00 00 00 01 IDR`; drop SEI(6)/AUD(9). **Port the SPS constraint-byte rewrite** (`67 42 xx 29` → set byte[2]=0x00) — the dash whitelists the stock SPS shape; this is essential.
- **RtpPacketizer:** identical — PT 96, 90 kHz clock, max payload 1380, **FU-A only (no STAP-A)**, marker on last packet of the access unit.

---

## 5. Off-screen map rendering

Android draws to a hardware Canvas on the encoder's input Surface. iOS path:
- Drive a **MapLibre `MLNMapSnapshotter`** (or a detached `MLNMapView` rendered to a Metal texture) at **2–4 fps**, motion-adaptive (4 fps moving / 2 fps idle), into a **`CVPixelBuffer` pool** sized 526×300.
- Composite overlays (route line, ETA pill, maneuver glyph, now-playing) with Core Graphics/Metal onto the buffer.
- Hand each buffer to `VTCompressionSession`. No window/screen needed — works with screen off under the location background mode.
- Frame caching: when nothing changed, re-feed the last buffer at idle rate + drop bitrate.

This is the second-riskiest piece after background execution — spike it in Phase 2 with a static test image before wiring the live map.

### 5.1 Idle dash wallpapers (OpenDash feature)

When **not navigating**, project a custom wallpaper to the dash instead of its stock standby — same projection pipeline, different content drawn into the frame. No new protocol risk; depends only on Phase 2 being proven.

- **Up to 5 media slots (gallery)**, cycled live with the **bike joystick** (media next/prev → already delivered as `09 00` button events by `DashSession`). No phone interaction while riding.
- **Three kinds:** still **image**, animated **GIF**, **video** (mp4/webm).
- **Crop/fit:** `CROP` / `FIT_HEIGHT` / `FIT_WIDTH` + horizontal/vertical bias, rendered to **526×300**.
- **Power-aware:** idle projection at **2 fps**; video-wallpaper frame decode capped at **8 fps** (125 ms) — preserves the screen-off thermal budget.

iOS port (`Dash/Video/DashIdleRenderer.swift` + `Data/DashWallpaperStore.swift`):

| Android | iOS |
|---|---|
| Canvas crop/fit → Bitmap | Core Graphics/Core Image → `CVPixelBuffer` (526×300) |
| GIF via `Movie` | ImageIO / `CGAnimateImageAtURL` frame extraction |
| Video via `MediaMetadataRetriever.getFrameAtTime` | `AVAssetImageGenerator.copyCGImage(at:)` (cap 8 fps), or `AVPlayerItemVideoOutput` |
| Pick ≤5 media | `PHPickerViewController` (multi-select) |
| Slots in prefs + filesDir | Documents container + `UserDefaults` |
| Joystick cycle | reuse `DashSession` button events |

Add to project structure under `Dash/Video/` and `Data/`; add a Wallpapers section to Settings. Built in **Phase 4** (after the projection pipeline is proven). Keep the `DashWallpaperPlaybackPolicy` 8-fps cap as a unit test, like the Android side.

---

## 6. Background execution strategy (the keep-alive)

1. Request **`Always`** location authorization; set `allowsBackgroundLocationUpdates = true`, `pausesLocationUpdatesAutomatically = false`, `activityType = .automotiveNavigation`.
2. Start continuous location updates the moment a dash session starts — this keeps the process alive with the screen off.
3. Keep encode + UDP work on background `DispatchQueue`s / `Task`s; CoreLocation prevents suspension.
4. **Fallback if location alone proves insufficient** under load: add the `audio` background mode + a silent `AVAudioPlayer` loop as a belt-and-suspenders keep-alive (test carefully — TestFlight tolerant, App Store would object). Prefer not to.
5. Show a persistent `MPNowPlayingInfoCenter`/Live Activity-style indicator so the user knows it's streaming.

**Phase 1, task 1 is literally just proving #1–#3 hold for 30+ minutes locked.**

---

## 7. Maps / routing / nav

- **Router.swift:** OSRM `/route/v1/driving` over HTTP; off-route detection + reroute (port logic from `Router.kt`/`LocationParser.kt`). Shared-link import: accept a Google Maps URL via the iOS **Share Extension** → resolve to coordinates.
- **NavEngine.swift:** compute current step, distance-to-turn, total remaining, ETA, maneuver glyph code → feed `DashSession.updateNavInfo` (drives `activeNavPacket`) and `updateRouteCard`. Reuse the dash unit conventions (`NAV_UNIT_METERS`/`KM_TENTHS`, ETA as 4 ASCII digits).
- **VoiceManager.swift:** AVSpeechSynthesizer; modes off / chime-before-turn / full TBT; route audio through the session so it ducks music.
- Offline regions (roadmap): MapLibre offline pack downloads.

---

## 8. Data layer & sync

- **GRDB** schema mirroring `NorthstarDb.kt`: rides, ride_points, maintenance_items, maintenance_log, fuel_entries, settings. Local SQLite is source of truth.
- **RideRecorder:** auto-record connect→disconnect: distance, duration, avg/max speed, track polyline.
- **Garage:** maintenance intervals + due reminders (local notifications via `UNUserNotificationCenter`), fuel diary with km/l + cost trends.
- **SyncRepository:** optional Firebase Auth (email) + Firestore mirror; 100% offline-local if no Firebase config. Same opt-in model as Android.

---

## 9. UI (SwiftUI, port of `ui/screens`)

Home, Route (preview + "Send to Dash"), Dash (live status, circular dash preview, on-screen joystick mirror), Rides (history + track maps), Garage (maintenance + fuel), Settings (voice mode, units, dash SSID, sync), Login. Reuse the existing Claude-Design screen specs from the Android repo's `docs/design/` as the visual reference.

---

## 10. Phased build plan (with hardware-validation gates)

> Mirrors the Android `CLAUDE.md` phasing, re-sequenced so iOS's risky bits are retired first. **Each phase ends with an on-bike validation gate.**

**Phase 0 — Foundations (no bike)**
Xcode project, SPM deps, entitlements, DI, GRDB schema, base SwiftUI shell. Build the **DashEmulator** tool (replays captured K1G packets over UDP) so the link layer is testable off-bike.

**Phase 1 — Link layer + the 3 existential risks (bike required)**
- 1a. **Background keep-alive spike** — prove screen-off survival for 30+ min. *Gate.*
- 1b. **Transport spike** — unicast vs broadcast control to the dash; choose path / file multicast entitlement. *Gate.*
- 1c. K1GPacket + DashCommands + DashAuth → full handshake to `07 01 01`. *Gate: handshake confirmed on your fw.*
- 1d. Stream a **static test image** end-to-end (encoder→NAL→RTP→dash) until `09 06 55` "decoded" ack appears. *Gate: dash shows our frame.*
- In parallel (no bike): standalone **Garage + Fuel diary + Ride history** — usable day one.

**Phase 2 — Off-screen map with screen OFF (bike)**
OffscreenMapRenderer → VideoToolbox → dash, motion-adaptive 2–4 fps, bitrate switching, frame caching. *Gate: live map on dash, phone screen off, thermals/battery measured.*

**Phase 3 — Navigation (bike)**
GPS + OSRM routing + reroute + turn-by-turn rendering + nav-info packets + joystick pan/zoom (`09 00`). Google Maps share import. *Gate: full guided ride.*

**Phase 4 — Polish + OpenDash extras**
Voice (TTS) modes, day/night, reconnect/auto-rejoin, settings, ride recording, Firebase sync, media now-playing (degraded), telemetry decode mapping (`0F`/`0C`). **OpenDash superset:** idle dash wallpapers (§5.1), multiple vehicle profiles, expenses tracking, PUC/insurance reminders, media/caller cards. TestFlight beta.

---

## 11. Testing strategy

- **DashEmulator** (host UDP tool replaying captured packets) → exercise auth/RX/keep-alives without the bike in CI.
- **Unit tests:** K1GPacket round-trips, RTP FU-A fragmentation, NAL splitting/SPS-rewrite, RSA ciphertext == 128 B, AES-CBC telemetry decrypt against a captured `0F` blob.
- **On-bike capture:** mirror Android's full-hex `DiagnosticsLog` so every unknown TLV (joystick-in-nav, maneuver glyphs) is recorded for protocol mapping.
- **Field metrics:** battery %/hr and thermal state (`ProcessInfo.thermalState`) over a real screen-off ride.

---

## 12. Open questions / risks (ranked)

1. **Background longevity** under sustained encode+UDP — must confirm location mode alone holds for hours (Risk: high → tested Phase 1a).
2. **Broadcast vs unicast** control plane on iOS (Risk: med → Phase 1b; mitigation = multicast entitlement).
3. **Fixed-port + interface-bound UDP** ergonomics in Network.framework (Risk: med → POSIX fallback ready).
4. **Per-firmware handshake** differences Himalayan vs Guerrilla (Risk: low/med → you have the bike; capture both if possible).
5. **TestFlight review** of background networking (Risk: low → location mode is legitimate for nav).
6. **Media now-playing** read restrictions (Risk: low → ship degraded, document gap).

---

## 13. Immediate next actions

1. Create the paid-team Xcode project + entitlements; **file the multicast entitlement request now** (long lead time) even while testing unicast.
2. Build **Phase 1a** (background keep-alive spike) and **Phase 0 DashEmulator** in parallel.
3. Capture a fresh K1G handshake from your bike (Himalayan and, if available, Guerrilla) with the Android app + packet logging, to seed the emulator and confirm fw parity.

---

## Appendix A — Platform approach decision (2026-06-28)

**Decision: native Swift, iOS only.**

React Native and Kotlin Multiplatform were considered. The deciding factor: this is a **real-time hardware video pipeline**, and its core — off-screen render → hardware H.264 encode (VideoToolbox/MediaCodec) → RTP/UDP, plus background-with-screen-off — must be written **natively per platform regardless of framework**, because MediaCodec (Android) and VideoToolbox (iOS) share no code.

- **React Native** — rejected: you'd still hand-write heavy Android + iOS native modules for the encoder/surface/background service, *plus* maintain JS/TS and the bridge — the most moving parts for the least benefit. Only the pure-bytes protocol layer shares cleanly.
- **Kotlin Multiplatform** — viable alternative if Android+iOS from one codebase were the goal (reuses OpenDash's existing Kotlin for protocol/data/logic; native encoders only). Not chosen because the priority is the best iOS app and an Android-native app already exists.
- **Native Swift** — chosen: cleanest, best-performing iOS app; the streaming core wouldn't share across platforms anyway.

This appendix records the rationale; the plan above is unchanged.
