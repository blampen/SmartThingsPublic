# ONVIF Cameras for Roku

A Roku channel for watching the IP cameras on your home network. It finds
cameras with ONVIF, logs in to them, and shows a grid of live thumbnails.
Open a camera to watch it full screen.

- **Discovery:** finds ONVIF cameras automatically (WS-Discovery), or you can
  add one by IP address.
- **Live grid:** each camera's picture refreshes every few seconds, with
  online, offline and login status.
- **Full screen:** live video through a small bridge on your network, or
  fast-refreshing snapshots with no extra software. Switch cameras with
  Left/Right and stream quality with Up/Down.
- **Logins:** one default login for all cameras, or a separate login per
  camera. The camera's clock is handled automatically.

## How it works

```
               ONVIF (SOAP over HTTP)
  Camera  <---------------------------->  Roku channel
     |      discovery, login, profiles,       ^   ^
     |      stream URIs, JPEG snapshots       |   | HLS video
     |                                        |   |
     |  RTSP          +----------------+      |   |
     +--------------> |  Video bridge  | -----+---+
                      |   (MediaMTX)   |  registers each camera
                      +----------------+  through the bridge API
```

Roku players can't play RTSP, which is what cameras stream, so the channel
works in one of two ways:

| Mode | Needs | What you get |
| --- | --- | --- |
| **Snapshots** | nothing extra | The camera's JPEG snapshots, refreshed as fast as it serves them (typically 2-5 fps) |
| **Live video** | [MediaMTX](https://github.com/bluenviron/mediamtx) on any always-on machine (PC, NAS, Raspberry Pi) | Full-motion H.264 video, about 2-5 s behind real time |

The bridge needs no camera configuration. When you open a camera, the channel
sends the camera's RTSP address to MediaMTX through its API. MediaMTX then
pulls the camera only while someone is watching and repackages the stream as
HLS, without re-encoding.

## 1. Install the channel

1. **Turn on developer mode on the Roku.** On the remote, press
   `Home ×3, Up ×2, Right, Left, Right, Left, Right`. Enable the installer,
   accept the license, and set a password. The Roku restarts.
2. **Sideload the channel.** Pick one:
   - `make install ROKU_IP=<roku ip> ROKU_PASS=<that password>`
   - Run `make`, open `http://<roku ip>` in a browser, log in as `rokudev`,
     and upload `out/roku-onvif-cameras.zip`.

The channel opens straight away and searches for cameras.

## 2. Set up the video bridge (optional, for live video)

On a machine on the same network as the cameras, with Docker installed:

```sh
cd bridge
docker compose up -d
```

Then in the channel, go to **Settings → Video bridge** and enter that
machine's IP address. **Test video bridge** checks the connection.

To run without Docker, download MediaMTX for your platform and start it
with this project's config: `./mediamtx bridge/mediamtx.yml`.

The bridge listens on ports 9997 (API), 8888 (HLS) and 8554 (RTSP). Keep
these on your LAN and never forward them from your router. The API accepts
camera passwords and is open to private-network addresses (see
`authInternalUsers` in `bridge/mediamtx.yml`).

## 3. Prepare your cameras

- **Turn on ONVIF.** Most cameras call it "ONVIF", "Open Network Video
  Interface" or "Integration Protocol". Many brands require a separate ONVIF
  user:
  - Hikvision: *Network → Advanced → Integration Protocol*
  - Tapo: *Advanced Settings → Camera Account*
  - Reolink: enable ONVIF under the network/server settings
- **Use the right port when adding by address.** The ONVIF port is often not
  80: Reolink commonly uses `8000`, Tapo `2020`. Enter it as
  `192.168.1.50:2020`.
- **Video settings for the smoothest playback:** H.264, with the I-frame
  (keyframe) interval equal to the frame rate. H.265 plays only on 4K Roku
  models, and only if you change `hlsVariant` to `fmp4` in
  `bridge/mediamtx.yml`.
- **Audio** plays only if the camera sends AAC. G.711 audio is dropped and
  the video plays silently.

## Hard-coded cameras (camera wall)

To build the camera list into the channel instead of discovering it, copy
`presets.example.json` to `presets.json` and edit it. Only the addresses
are required.

```json
{
  "user": "admin",
  "pass": "camera password",
  "cameras": [
    { "name": "Front Door", "address": "192.168.0.20" },
    { "name": "Garage", "address": "192.168.0.21:8000", "user": "viewer", "pass": "other" }
  ],
  "settings": { "refreshSec": 1, "bridgeHost": "192.168.0.10" }
}
```

`make` packs `presets.json` into the zip. Git ignores it, so the passwords
never reach the repository. With presets, the channel works differently:

- Up to four cameras fill the screen as a 2×2 wall, with no search or add
  tiles. `*` opens a camera's options, which include Settings.
- For a bare IP like `192.168.0.20`, the channel finds the ONVIF port itself
  (80, 8000, 2020, 8899, 8080 or 5000) and remembers it.
- Logins come only from the file. A camera that rejects its login shows the
  error on its tile; fix `presets.json` and reinstall.
- `settings` sets defaults; changes made in the Settings screen still win.

## Using the channel

| Screen | Key | Action |
| --- | --- | --- |
| Grid | OK | Open camera / enter a missing login / see why a camera is offline |
| Grid | `*` | Camera options: stream, rename, login, address, reconnect, remove |
| Full screen | Left / Right | Previous / next camera |
| Full screen | Up / Down | Higher / lower quality stream (camera profile) |
| Full screen | `*` | Switch between live video and snapshots |
| Full screen | OK | Show / hide the info bar |
| Full screen | Replay | Reconnect |

The **Settings** tile holds the default camera login, the bridge address and
ports, whether cameras open in video or snapshot mode, and how often
thumbnails refresh.

## Troubleshooting

- **No cameras found.** Discovery uses multicast and only reaches cameras on
  the same subnet as the Roku. Cameras on another VLAN, or Wi-Fi with client
  isolation, won't be found. Add them by address instead.
- **"Login needed" or "Login failed".** Check that you are using the camera's
  *ONVIF* user (see above). The channel corrects for clock differences
  between the Roku and the camera, so time settings aren't the cause.
- **Live video never starts.** After 25 seconds the channel falls back to
  snapshots and shows the reason. To find the cause:
  - Check the bridge log: `docker logs roku-camera-bridge`.
  - Try the re-stream in VLC: `rtsp://<bridge ip>:8554/<path>`. The path is
    shown in the log, as `roku_...`.
  - Check the codec. H.265 needs the `fmp4` change above.
- **No thumbnail, but video works.** Some cameras don't implement ONVIF
  snapshots. Use the bridge for those.

## Limitations

- Live video needs the bridge; Roku has no RTSP player.
- Uses the ONVIF Media (ver10) service, which Profile S cameras (nearly all of
  them) implement. PTZ, two-way audio, events and recordings are not
  supported.
- Camera passwords are stored in this channel's private Roku registry.

## Development

```
manifest
source/                 main.brs plus libraries shared with components:
  Onvif.brs             SOAP, WS-Security digest, discovery parsing, probe flow
  Http.brs              blocking HTTP for Task threads
  Snapshots.brs         non-blocking snapshot poller
  Bridge.brs            MediaMTX path registration
  Store.brs, Util.brs   registry, URL and XML helpers
components/
  MainScene             camera list, discovery, probing, navigation
  grid/                 home grid and tiles
  viewer/               full screen video / snapshot viewer
  settings/             settings screen
  tasks/                Discovery, Onvif, Snapshot and Bridge Task nodes
bridge/                 MediaMTX config + docker-compose
tests/                  fake ONVIF camera and off-device tests
```

```sh
npm install
npm run lint   # BrighterScript compiler + bslint
npm test       # BrightScript tests in brs-node against the fake camera,
               # plus bridge tests if `mediamtx` and `ffmpeg` are installed
```

`tests/fake_onvif_camera.py` is a simulated ONVIF camera. It supports
WS-Discovery, WS-Security with an optionally skewed clock, profiles, and
snapshots behind Basic or Digest auth. Use it to try the channel without
hardware:

```sh
python3 tests/fake_onvif_camera.py --host <this machine's ip> --rtsp-url rtsp://<ip>:8554/fakecam
```
