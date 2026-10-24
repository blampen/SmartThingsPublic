# ONVIF Cameras for Roku

A Roku channel for watching the IP cameras on your home network. It finds
cameras with ONVIF, logs in to them, and shows them all at once. Open a
camera to watch it full screen.

- **Camera wall:** four cameras fill the screen edge to edge as live video.
  Move the highlight with the arrow keys to hear that camera; press OK to
  watch it full screen and Back to return.
- **Camera grid:** with discovery instead of a fixed list, a grid of live
  thumbnails with online, offline and login status.
- **Full screen:** the camera's own stream (H.264 or H.265) with sound.
  Switch cameras with Left/Right and stream quality with Up/Down.
- **Discovery and logins:** finds ONVIF cameras automatically
  (WS-Discovery), or uses a fixed list built into the channel. The camera's
  clock and ONVIF port are handled automatically.

## How it works

```
               ONVIF (SOAP over HTTP)
  Camera  <---------------------------->  Roku channel
     |      discovery, login, profiles,      ^   ^
     |      stream URIs, JPEG snapshots      |   | HLS: "wall" (4-up) or
     |                                       |   |      "full<N>" (one camera)
     |  RTSP         +-----------------+     |   |
     +-------------> |  Video bridge   | ----+---+
                     | MediaMTX+ffmpeg |  registers each camera's
                     +-----------------+  streams through the API
```

A Roku can't play RTSP, which is what cameras stream, and plays only one
video at a time. Live video therefore goes through a bridge on your network:

- **The wall:** the bridge tiles cameras 1-4 into one 1920×1080 picture with
  no gaps. Each camera's sound becomes its own audio track; highlighting a
  camera switches the TV to its track.
- **Full screen:** the camera's stream is passed through without
  re-encoding (H.265 stays H.265). Only the sound is converted to AAC, since
  cameras usually send G.711, which the Roku can't play.

Without a bridge the channel still works, with snapshots instead of video:

| Mode | Needs | What you get |
| --- | --- | --- |
| **Snapshots** | nothing extra | Each camera's JPEG snapshots, refreshed every 1-3 s (2-5 fps full screen); no sound |
| **Live video** | the bridge on an always-on PC, NAS or mini PC | Full-motion video with sound, about 3-6 s behind real time |

## 1. Install the channel

1. **Turn on developer mode on the Roku** (this works the same on a Roku TV
   such as a Hisense). On the remote, press
   `Home ×3, Up ×2, Right, Left, Right, Left, Right`. Enable the installer,
   accept the license, and set a password. The Roku restarts.
2. **Sideload the channel.** Pick one:
   - `make install ROKU_IP=<roku ip> ROKU_PASS=<that password>`
   - Run `make`, open `http://<roku ip>` in a browser, log in as `rokudev`,
     and upload `out/roku-onvif-cameras.zip`.

## 2. Set up the video bridge (for live video and sound)

On a machine on the same network as the cameras, with Docker installed:

```sh
cd bridge
docker compose up -d
```

Then in the channel, open **Settings → Video bridge** and enter that
machine's IP address. **Test video bridge** checks the connection. On the
camera wall, Settings is in the `*` menu.

The bridge uses the `bluenviron/mediamtx:1-ffmpeg` image with
`bridge/mediamtx.yml` and the scripts in `bridge/scripts/`; you don't list
cameras anywhere. The wall re-encodes four small streams into one 1080p
picture, which takes roughly half to one core of a recent x86 CPU. Any
current PC, NAS or mini PC is fine; a Raspberry Pi will likely struggle with the
wall. Full screen only repackages, so it costs almost nothing.
`docker-compose.yml` has the settings:

| Setting | Default | Meaning |
| --- | --- | --- |
| `WALL_STREAM` | `sub` | Build the wall from the cameras' sub streams (light) or `main` streams (sharper, needs a fast CPU) |
| `WALL_FPS` | `15` | Wall frame rate |
| `WALL_BITRATE` | `6M` | Wall video bitrate |

The wall starts the first time the Roku asks for it, which takes about 10
seconds. It keeps running for 2 minutes after you leave it, so coming back
from full screen is quick. To keep it running all the time, add
`MTX_PATHS_WALL_RUNONDEMANDCLOSEAFTER: 24h` to the environment. When a
camera drops out, the wall rebuilds without it within about 20 seconds, and
again when the camera comes back.

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
- **Turn on audio** for the stream (often a "Video & Audio" stream type),
  on the main stream, the sub stream, or both. The wall takes sound from the
  sub stream if it has it, otherwise from the main stream.
- **Video settings:** H.264 or H.265. H.265 full screen needs a 4K Roku or
  4K Roku TV; the channel checks and falls back to snapshots with a
  message if the TV can't decode it. Set the I-frame (keyframe) interval
  equal to the frame rate for the lowest delay. Give the sub stream at
  least 640×360; it fills a quarter of the wall.

## Hard-coded cameras (the camera wall)

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

- The home screen is the camera wall: the first four cameras in the file,
  in order (top left, top right, bottom left, bottom right). There are no
  search or add tiles.
- For a bare IP like `192.168.0.20`, the channel finds the ONVIF port itself
  (80, 8000, 2020, 8899, 8080 or 5000) and remembers it.
- Logins come only from the file. A camera that rejects its login shows the
  error in its quarter; fix `presets.json` and reinstall.
- `settings` sets defaults; changes made in the Settings screen still win.

## Using the channel

| Screen | Key | Action |
| --- | --- | --- |
| Camera wall | Arrows | Highlight a camera and switch the sound to it |
| Camera wall | OK | Watch the highlighted camera full screen |
| Camera wall | `*` | Camera options: stream, reconnect, Settings |
| Grid | OK | Open camera / enter a missing login / see why a camera is offline |
| Grid | `*` | Camera options: stream, rename, login, address, reconnect, remove |
| Full screen | Back | Return to the wall or grid |
| Full screen | Left / Right | Previous / next camera |
| Full screen | Up / Down | Higher / lower quality stream (camera profile) |
| Full screen | `*` | Switch between live video and snapshots |
| Full screen | OK | Show / hide the info bar |
| Full screen | Replay | Reconnect |

On the wall, the highlight and the camera's name show for a few seconds
after each key press, then fade, leaving only the feeds. A small speaker
icon marks the camera you're hearing.

## Troubleshooting

- **No cameras found.** Discovery uses multicast and only reaches cameras on
  the same subnet as the Roku. Cameras on another VLAN, or Wi-Fi with client
  isolation, won't be found. Add them by address instead.
- **"Login needed" or "Login failed".** Check that you are using the camera's
  *ONVIF* user (see above). The channel corrects for clock differences
  between the Roku and the camera, so time settings aren't the cause.
- **The wall shows snapshots, not video.** The channel keeps retrying the
  bridge. To find the cause:
  - Check the bridge log: `docker logs roku-camera-bridge`.
  - Open the wall in VLC: `http://<bridge ip>:8888/wall/index.m3u8`, or a
    single camera at `rtsp://<bridge ip>:8554/cam1_main`.
- **A quarter of the wall is black.** That camera isn't reachable or
  rejected its login (its quarter shows why when the video stops). The wall
  rebuilds when the camera comes back.
- **No sound.** Turn on audio in the camera's stream settings (see above).
  Sound needs the bridge.
- **Full screen falls back to snapshots.** Look at the info bar (press OK):
  it says why, for example an H.265 stream on a TV that can't decode H.265.

## Limitations

- Live video and sound need the bridge; Roku has no RTSP player and plays
  one video at a time.
- Switching the sound on the wall switches audio tracks in the player,
  which can take a moment.
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
  Bridge.brs            MediaMTX path registration, wall audio tracks
  Store.brs, Util.brs   registry, presets, stream choice, URL and XML helpers
components/
  MainScene             camera list, discovery, probing, navigation
  wall/                 four-feed camera wall (fixed cameras)
  grid/                 camera grid and tiles (discovered cameras)
  viewer/               full screen video / snapshot viewer
  settings/             settings screen
  tasks/                Discovery, Onvif, Snapshot and Bridge Task nodes
bridge/                 MediaMTX config, docker-compose, scripts/ for the
                        wall and full screen streams
tests/                  fake ONVIF camera and off-device tests
```

```sh
npm install
npm run lint   # BrighterScript compiler + bslint
npm test       # BrightScript tests in brs-node against the fake camera,
               # plus bridge tests (wall and full screen) if `mediamtx`
               # and `ffmpeg` (with libx265) are installed
```

`tests/fake_onvif_camera.py` is a simulated ONVIF camera. It supports
WS-Discovery, WS-Security with an optionally skewed clock, profiles, and
snapshots behind Basic or Digest auth. Use it to try the channel without
hardware:

```sh
python3 tests/fake_onvif_camera.py --host <this machine's ip> --rtsp-url rtsp://<ip>:8554/fakecam
```
