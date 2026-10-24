#!/bin/sh
# Full screen feed for camera $1 (MediaMTX path full<N>): the camera's own
# video passed through untouched (H.265 stays H.265, no re-encoding), with
# its sound converted to AAC, which HLS and the Roku can play (cameras
# usually send G.711). MediaMTX runs this on demand and it publishes back
# to $MTX_PATH. The Roku registers the camera's stream as cam<N>_main.

RTSP="rtsp://127.0.0.1:${RTSP_PORT:-8554}"
exec ffmpeg -hide_banner -loglevel warning \
    -rtsp_transport tcp -timeout 10000000 -i "$RTSP/cam$1_main" \
    -map 0:v:0 -map "0:a:0?" -c:v copy -c:a aac -b:a 96k -ar 48000 -ac 2 \
    -f rtsp -rtsp_transport tcp "$RTSP/$MTX_PATH"
