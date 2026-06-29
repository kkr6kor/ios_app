# Cairn

**Low-power motorcycle navigation for the Royal Enfield Tripper dash — with the phone screen off.** An iOS app for the **Himalayan 450** and **Guerrilla 450**.

Cairn renders a map/navigation view **off-screen**, hardware-encodes it to **H.264**, and streams it to the bike's round **Tripper TFT dash** over Wi-Fi — so the phone screen can stay **off** the whole ride (saving battery and avoiding thermal throttling). It's an independent Swift port of the Android projects [NorthStar](https://github.com/adityadasika21/NorthStar) / [OpenDash](https://github.com/subtlesayak/open-dash).

> ⚠️ Independent, community project. **Not affiliated with, endorsed by, or supported by Royal Enfield.** The dash link is unofficial — it only streams video to the dash display and reads joystick input; it never touches the ECU, engine, or brakes. Use at your own risk. Validated against firmware **11.63**; other firmwares may differ.

---

## How it works

```
Destination (MapKit search) ─▶ route (OSRM) ─▶ off-screen render (MapLibre + CoreGraphics)
                                                       │
                                          VideoToolbox H.264 (hardware)
                                                       │
                                              RTP over UDP :5000
                                                       ▼
                                                  Tripper Dash
        (K1G control plane over UDP :2000 · RSA-1024 + AES-256 auth)
```

## Features

- **Navigation** — destination search (keyless MapKit), OSRM routing, turn-by-turn with distance-to-turn / ETA, automatic off-route rerouting, joystick zoom, on-device voice guidance (off / chime / full).
- **Live dash map** — MapLibre + OpenFreeMap basemap (keyless) rendered off-screen, with the route + position overlaid; falls back to a line-only view when offline.
- **Idle wallpaper** — up to 5 image / GIF / video wallpapers projected to the dash while idle, joystick-cycled, with crop/fit controls.
- **Garage** — vehicles, maintenance log with service-interval due flags, PUC / insurance expiry reminders (local notifications).
- **Fuel** — fill-ups with automatic mileage (km/l).
- **Expenses** — multi-category tracking with monthly / all-time totals.
- **Rides** — ride history (auto-recorded during navigation).

## Tech

- **Swift / SwiftUI**, iOS 16+
- **VideoToolbox** hardware H.264 → custom RFC 6184 RTP packetizer → UDP
- **MapLibre Native** + **OpenFreeMap** (keyless); **OSRM** routing
- **Security framework** (RSA-1024) + **CommonCrypto** (AES-256) for the dash handshake
- **CoreLocation** background mode keeps streaming alive with the screen off

## Building

Requires Xcode 16+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (the `.xcodeproj` is generated, not committed):

```bash
brew install xcodegen
git clone https://github.com/ashifkhn/Cairn.git
cd Cairn
xcodegen generate
open Cairn.xcodeproj
```

Set your Apple Developer team (`DEVELOPMENT_TEAM` in `project.yml`) to run on a device.

### Signing notes

- **Free (personal) Apple teams** can't use the Hotspot or Multicast entitlements, so Cairn joins the dash Wi-Fi **manually** (you join the `RE_` network in iOS Settings, password `12345678`, and type the SSID in-app) and uses **unicast** control. This works without a paid account.
- **Paid program** adds programmatic Wi-Fi join (`NEHotspotConfiguration`) and UDP broadcast (`com.apple.developer.networking.multicast`, requires Apple approval). The entitlements are pre-written and commented in `Cairn/Resources/Cairn.entitlements`.

## Status

The standalone features (Garage, Fuel, Expenses, Rides, Wallpaper) and the navigation + dash link layer are implemented and unit-tested. The dash streaming path requires **hardware-in-the-loop validation on a real bike** — maneuver glyph codes and joystick button codes still need on-bike capture. See [`IMPLEMENTATION_PLAN.md`](IMPLEMENTATION_PLAN.md) for the full architecture and roadmap.

## License

[Apache License 2.0](LICENSE). Protocol understanding is cross-checked against the open-source [NorthStar](https://github.com/adityadasika21/NorthStar), [OpenDash](https://github.com/subtlesayak/open-dash), and [better-dash](https://github.com/norbertFeron/better-dash) projects (also Apache-2.0); see [`NOTICE`](NOTICE).
