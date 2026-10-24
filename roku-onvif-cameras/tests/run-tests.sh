#!/usr/bin/env bash
# Runs the BrightScript tests off-device with brs-node against the fake ONVIF
# camera. If `mediamtx` and `ffmpeg` are on PATH (or MEDIAMTX points at the
# binary) the bridge tests run too, using bridge/mediamtx.yml unchanged.
#
#   npm install && npm test
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BRS_CLI="${BRS_CLI:-$ROOT/node_modules/.bin/brs-cli}"
MEDIAMTX="${MEDIAMTX:-$(command -v mediamtx || true)}"
WORK="$(mktemp -d)"
CAM_PORT=18081
CAM_RTSP_PORT=18554
SKEW=3600
PIDS=()

cleanup() {
    for pid in "${PIDS[@]}"; do kill "$pid" 2>/dev/null || true; done
    rm -rf "$WORK"
}
trap cleanup EXIT

wait_for_port() {
    for _ in $(seq 1 50); do
        if (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; then return 0; fi
        sleep 0.2
    done
    echo "port $1 never opened" >&2
    return 1
}

if [[ ! -x "$BRS_CLI" ]]; then
    echo "brs-cli not found; run 'npm install' in $ROOT first" >&2
    exit 1
fi

# The camera reports a stale IP (10.255.255.1) in every URL and runs an hour
# fast, the two quirks most likely to break a client in the field.
python3 "$ROOT/tests/fake_onvif_camera.py" --host 127.0.0.1 --port "$CAM_PORT" \
    --advertise-host 10.255.255.1 --clock-skew "$SKEW" --snapshot-auth basic --no-discovery \
    --rtsp-url "rtsp://{host}:$CAM_RTSP_PORT/fakecam" > "$WORK/camera.log" 2>&1 &
PIDS+=($!)
wait_for_port "$CAM_PORT"

LAUNCH="camera=127.0.0.1:$CAM_PORT,skew=$SKEW,rtsp=$CAM_RTSP_PORT"

if [[ -n "$MEDIAMTX" ]] && command -v ffmpeg > /dev/null; then
    # A second MediaMTX plays the camera's own RTSP server, fed by a test
    # pattern; the bridge under test then pulls from it like a real camera.
    cat > "$WORK/camera-rtsp.yml" <<EOF
rtspAddress: :$CAM_RTSP_PORT
rtspTransports: [tcp]
hls: false
rtmp: false
webrtc: false
srt: false
api: false
moq: false
paths:
  fakecam:
    source: publisher
EOF
    "$MEDIAMTX" "$WORK/camera-rtsp.yml" > "$WORK/camera-rtsp.log" 2>&1 &
    PIDS+=($!)
    wait_for_port "$CAM_RTSP_PORT"
    ffmpeg -nostdin -loglevel error -re -f lavfi -i testsrc2=size=1280x720:rate=15 \
        -c:v libx264 -preset ultrafast -tune zerolatency -g 15 -pix_fmt yuv420p \
        -f rtsp -rtsp_transport tcp "rtsp://127.0.0.1:$CAM_RTSP_PORT/fakecam" > "$WORK/ffmpeg.log" 2>&1 &
    PIDS+=($!)

    (cd "$WORK" && exec "$MEDIAMTX" "$ROOT/bridge/mediamtx.yml" > "$WORK/bridge.log" 2>&1) &
    PIDS+=($!)
    wait_for_port 9997
    LAUNCH="$LAUNCH,bridge=127.0.0.1"
else
    echo "mediamtx/ffmpeg not found: skipping bridge tests"
fi

SOURCES=(Util.brs Http.brs Onvif.brs Store.brs Bridge.brs Snapshots.brs)
FILES=()
for f in "${SOURCES[@]}"; do FILES+=("$ROOT/source/$f"); done
FILES+=("$ROOT/tests/OnvifTests.brs")

OUTPUT="$("$BRS_CLI" --no-sg -k "$LAUNCH" "${FILES[@]}" 2>&1 | grep -vE 'Network Gateway|spawnSync ip' || true)"
echo "$OUTPUT"

if ! grep -qE '^TESTS: [0-9]+ passed, 0 failed' <<< "$OUTPUT"; then
    echo "--- camera log ---"; tail -n 30 "$WORK/camera.log"
    [[ -f "$WORK/bridge.log" ]] && { echo "--- bridge log ---"; tail -n 30 "$WORK/bridge.log"; }
    exit 1
fi
