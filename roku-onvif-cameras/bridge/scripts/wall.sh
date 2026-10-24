#!/bin/sh
# The four-camera wall the Roku shows on its home screen: cameras 1-4 tiled
# 2x2 into one 1920x1080 H.264 picture with no gaps, plus each camera's
# sound as its own AAC track (audio track N = camera N), so the TV switches
# sound by switching tracks. A camera that can't be opened shows black and
# is silent. MediaMTX runs this on demand (and again whenever it exits) and
# it publishes back to $MTX_PATH; the watcher below makes it exit when a
# camera drops out or comes back, so the wall rebuilds around it.
#
# The Roku registers each camera's streams as cam<N>_main and cam<N>_sub.
# Settings (environment): WALL_STREAM sub|main, WALL_FPS, WALL_BITRATE,
# WALL_API_PORT (MediaMTX apiAddress port, default 9997).

RTSP="rtsp://127.0.0.1:${RTSP_PORT:-8554}"
API="http://127.0.0.1:${WALL_API_PORT:-9997}"
STREAM="${WALL_STREAM:-sub}"
FPS="${WALL_FPS:-15}"
BITRATE="${WALL_BITRATE:-6M}"
# Inputs are opened one after another, so keep stream analysis short.
# (Expanded unquoted below, on purpose, to split into arguments.)
INPUT="-thread_queue_size 1024 -rtsp_transport tcp -timeout 10000000 -analyzeduration 500000"
TMP=$(mktemp -d)

# probe URL FILE: writes the stream types found (video, audio), one per line.
probe() {
    ffprobe -v error -rtsp_transport tcp -timeout 10000000 -analyzeduration 1000000 \
        -show_entries stream=codec_type -of csv=p=0 "$1" > "$2" 2>/dev/null
}

for i in 1 2 3 4; do
    probe "$RTSP/cam${i}_$STREAM" "$TMP/tile$i" &
    # Sub streams often carry no sound; the main stream may.
    probe "$RTSP/cam${i}_main" "$TMP/main$i" &
done
wait

set --
n=0
filters=""
missing=""
live=""
for i in 1 2 3 4; do
    audio=""
    if grep -q video "$TMP/tile$i"; then
        # shellcheck disable=SC2086
        set -- "$@" $INPUT -i "$RTSP/cam${i}_$STREAM"
        live="$live cam${i}_$STREAM"
        filters="${filters}[$n:v:0]scale=960:540:force_original_aspect_ratio=increase,crop=960:540,setsar=1,fps=${FPS}[v$i];"
        if grep -q audio "$TMP/tile$i"; then audio="$n:a:0"; fi
        n=$((n + 1))
    else
        missing="$missing $i"
        set -- "$@" -re -f lavfi -i "color=c=black:s=960x540:r=$FPS"
        filters="${filters}[$n:v:0]setsar=1[v$i];"
        n=$((n + 1))
    fi
    if [ -z "$audio" ] && [ "$STREAM" != main ] && grep -q audio "$TMP/main$i"; then
        # shellcheck disable=SC2086
        set -- "$@" $INPUT -vn -i "$RTSP/cam${i}_main"
        live="$live cam${i}_main"
        audio="$n:a:0"
        n=$((n + 1))
    fi
    if [ -z "$audio" ]; then
        set -- "$@" -re -f lavfi -i "anullsrc=r=48000:cl=stereo"
        audio="$n:a:0"
        n=$((n + 1))
    fi
    filters="${filters}[$audio]aresample=48000:async=1,aformat=sample_rates=48000:channel_layouts=stereo[a$i];"
done
filters="${filters}[v1][v2][v3][v4]xstack=inputs=4:layout=0_0|w0_0|0_h0|w0_h0[v]"

# Watcher: stops the wall (exec below makes $$ the ffmpeg process) so that
# MediaMTX rebuilds it when
#  - a camera in it stops sending; ffmpeg would otherwise wait for it and
#    freeze the whole picture (checked every 10 s), or
#  - a missing camera answers again (checked every 30 s).
(
    tick=0
    while sleep 10 && kill -0 $$ 2>/dev/null; do
        for path in $live; do
            if wget -qO- "$API/v3/paths/get/$path" 2>/dev/null | grep -q '"ready":false'; then
                kill $$
                break 2
            fi
        done
        tick=$((tick + 1))
        if [ $((tick % 3)) -eq 0 ]; then
            for i in $missing; do
                probe "$RTSP/cam${i}_$STREAM" "$TMP/check"
                if grep -q video "$TMP/check"; then
                    kill $$
                    break 2
                fi
            done
        fi
    done
    rm -rf "$TMP"
) &

exec ffmpeg -hide_banner -loglevel warning "$@" \
    -filter_complex "$filters" \
    -map "[v]" -map "[a1]" -map "[a2]" -map "[a3]" -map "[a4]" \
    -c:v libx264 -preset veryfast -tune zerolatency -profile:v high -pix_fmt yuv420p \
    -b:v "$BITRATE" -maxrate "$BITRATE" -bufsize "$BITRATE" -g "$FPS" -keyint_min "$FPS" -sc_threshold 0 \
    -c:a aac -b:a 64k \
    -f rtsp -rtsp_transport tcp "$RTSP/$MTX_PATH"
