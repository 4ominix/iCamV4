# iCamV4

Virtual camera tweak for jailbroken iOS 15+. Replaces the real camera feed with a custom source — static image, looping video, or live RTMP stream from OBS Studio.

No account, no login, no license server. Fully offline and local.

## Features

- **Camera Hook** — Injects into `cameracaptured` / `mediaserverd` via MobileSubstrate. Replaces `CMSampleBuffer` in real-time with rendered frames from your chosen source.
- **RTMP Server** — Built-in RTMP daemon on port 1935. Point OBS at `rtmp://<device-ip>:1935/live` and your stream becomes the camera feed.
- **Media Sources** — Import images or videos from Photo Library or Files. Static image, looping video, or live stream.
- **Floating Overlay** — Draggable button on SpringBoard to toggle the virtual camera without opening the app. Shows server status and client count.
- **Full App UI** — Select source, manage media library, copy OBS URL, toggle camera. Dark mode.

## Architecture

```
OBS Studio ──RTMP──▶ VCFStreamDaemon ──FLV──▶ iCamV4/Streams/
                                                      │
App (select source) ──plist──▶ CameraConfig.plist ◀────┤
                                                      │
                     VCFCameraHook (in mediaserverd) ◀─┘
                           │
                    swap CMSampleBuffer
                           │
                     ▼ every app sees fake camera
```

| Module | Injects Into | Purpose |
|---|---|---|
| `VCFCameraHook.dylib` | `cameracaptured`, `mediaserverd` | Hook camera pipeline, replace frames |
| `VCFOverlay.dylib` | `SpringBoard` | Floating toggle button + status panel |
| `VCFStreamDaemon` | standalone daemon | RTMP server, writes FLV to shared dir |
| `VCamFree.app` | standalone app | UI for config, media import, OBS URL |

## Build

Requires [Theos](https://theos.dev/docs/installation) on macOS or Linux.

```bash
git clone https://github.com/4ominix/iCamV4.git
cd iCamV4
make package FINALPACKAGE=1
```

Output: `packages/com.vcamfree.app_1.0.0_iphoneos-arm.deb`

## Install

1. Transfer the `.deb` to your device
2. Install via Filza / Sileo / Zebra / `dpkg -i`
3. Respring

## Usage

1. Open **VCamFree** app
2. Import an image or video from your library
3. Select source mode: **Image**, **Video**, or **RTMP Stream**
4. Toggle **Enable Virtual Camera**
5. For OBS: copy the RTMP URL from the app, paste into OBS → Settings → Stream → Custom
6. Use the floating button on SpringBoard for quick toggle

## Requirements

- iOS 15.0+
- Jailbroken device with MobileSubstrate / Substitute
- `arm64` or `arm64e`

## File Paths

| Path | Purpose |
|---|---|
| `/var/jb/var/mobile/Library/VCamFree/Media/` | Imported images and videos |
| `/var/jb/var/mobile/Library/VCamFree/Streams/` | RTMP stream FLV cache |
| `/var/jb/var/mobile/Library/VCamFree/CameraConfig.plist` | Camera configuration |
| `/var/jb/var/mobile/Library/VCamFree/CameraStatus.plist` | Camera hook status |
| `/var/jb/var/mobile/Library/VCamFree/ServerStatus.plist` | RTMP server status |

## License

Do whatever you want with it.
