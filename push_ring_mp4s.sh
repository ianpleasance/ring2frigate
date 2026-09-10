#!/usr/bin/env bash
#
# Watches one directory per Ring camera. Whenever a new .mp4 lands, pushes
# it into Frigate (via go2rtc's built-in RTSP server) in real time, exactly
# once, then renames it to <file>.mp4.done so it's never reprocessed.
#
# Each camera gets its own background watcher, so 20 cameras run in
# parallel - but within a single camera, files are always pushed one at a
# time, in order, never overlapping.
#
# Requires: ffmpeg, inotify-tools (for `inotifywait`)
#   Debian/Ubuntu: sudo apt install ffmpeg inotify-tools
#
# Usage:
#   ./push_ring_mp4s.sh [cameras.conf]
#
# Run this as a systemd service or in a `screen`/`tmux` session so it
# keeps running. See the bottom of this file for a sample systemd unit.

set -uo pipefail

CONFIG_FILE="${1:-${CONFIG_FILE:-./cameras.conf}}"
RTSP_HOST="${RTSP_HOST:-127.0.0.1}"
RTSP_PORT="${RTSP_PORT:-8554}"
LOG_DIR="${LOG_DIR:-/var/log/ring-frigate}"

# Frigate's own ffmpeg only (re)connects to go2rtc on its own retry cycle,
# which can leave gaps of 10-30+ seconds between attempts. A clip that's
# only a few seconds long can easily finish publishing and vanish again
# before Frigate ever tries to connect during that window - so it's
# silently missed entirely (no error anywhere, it just never got captured).
# To make that overlap reliable, we repeat-publish the same clip
# back-to-back until at least this many seconds have elapsed in total.
MIN_PUBLISH_SECONDS="${MIN_PUBLISH_SECONDS:-45}"

mkdir -p "$LOG_DIR"

log() {
    local camera="$1"; shift
    echo "$(date '+%F %T') [$camera] $*" >> "$LOG_DIR/${camera}.log"
}

process_file() {
    local camera="$1"
    local file="$2"
    local rtsp_url="rtsp://${RTSP_HOST}:${RTSP_PORT}/${camera}"

    # Belt-and-braces: never touch a file that's already marked done
    [[ "$file" == *.done ]] && return

    local ok=true
    if [[ "$MIN_PUBLISH_SECONDS" -le 0 ]]; then
        log "$camera" "pushing $file (single pass, no repeat - MIN_PUBLISH_SECONDS=0)"
        if ! ffmpeg -nostdin -loglevel error -re -i "$file" -c copy -rtsp_transport tcp -f rtsp "$rtsp_url" \
            >>"$LOG_DIR/${camera}.log" 2>&1; then
            ok=false
        fi
    else
        log "$camera" "pushing $file (looping in a single continuous stream for ${MIN_PUBLISH_SECONDS}s, so timestamps stay monotonic and Frigate's retry cycle has a chance to catch it)"
        # -stream_loop replays the input inside the SAME ffmpeg process, so
        # timestamps keep increasing continuously across loop boundaries -
        # unlike restarting ffmpeg per loop, which resets timestamps to 0
        # each time and causes Frigate's recorder to drop most frames as
        # non-monotonic (this is what produced the near-frozen ~0.23fps
        # recordings). -t caps total output at the target duration whether
        # the source is shorter (loops to fill it) or longer (cuts it off).
        if ! ffmpeg -nostdin -loglevel error -stream_loop -1 -re -i "$file" -t "$MIN_PUBLISH_SECONDS" \
            -c copy -rtsp_transport tcp -f rtsp "$rtsp_url" \
            >>"$LOG_DIR/${camera}.log" 2>&1; then
            ok=false
        fi
    fi

    if $ok; then
        mv -- "$file" "${file}.done"
        log "$camera" "done -> ${file}.done"
    else
        log "$camera" "FAILED (leaving file in place so it's retried next run): $file"
    fi
}

watch_camera() {
    local camera="$1"
    local dir="$2"

    mkdir -p "$dir"
    log "$camera" "watching $dir"

    # Catch up on any backlog first, oldest file first, strictly one at a time
    find "$dir" -maxdepth 1 -type f -name '*.mp4' -printf '%T@ %p\0' 2>/dev/null \
        | sort -z -n \
        | cut -z -d' ' -f2- \
        | while IFS= read -r -d '' f; do
            process_file "$camera" "$f"
        done

    # Then watch for new files landing (Ring delivery scripts usually either
    # write-then-close or move-into-place, so we catch both)
    inotifywait -m -e close_write -e moved_to --format '%f' "$dir" 2>>"$LOG_DIR/${camera}.log" \
        | while read -r filename; do
            [[ "$filename" == *.mp4 ]] && process_file "$camera" "$dir/$filename"
        done
}

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "Config file not found: $CONFIG_FILE" >&2
    exit 1
fi

pids=()
pid_cameras=()
while IFS=':' read -r camera dir || [[ -n "$camera" ]]; do
    [[ -z "$camera" || "$camera" == \#* ]] && continue
    dir="${dir%/}"
    watch_camera "$camera" "$dir" &
    pids+=("$!")
    pid_cameras+=("$camera")
done < "$CONFIG_FILE"

echo "Started ${#pids[@]} camera watchers. Logs in $LOG_DIR/<camera>.log"

# Actively supervise the watchers instead of a bare `wait`. If any single
# camera's watcher dies (e.g. its inotifywait process crashes), the other
# watchers would otherwise keep running silently and this container would
# never exit - so Docker's restart policy would never notice the problem.
# Exiting non-zero here instead lets `restart: unless-stopped` (or a
# systemd Restart=on-failure) actually catch it and respawn everything.
while true; do
    for i in "${!pids[@]}"; do
        pid="${pids[$i]}"
        camera="${pid_cameras[$i]}"
        if ! kill -0 "$pid" 2>/dev/null; then
            echo "$(date '+%F %T') [$camera] watcher (pid $pid) exited unexpectedly - restarting" \
                | tee -a "$LOG_DIR/${camera}.log" >&2
            exit 1
        fi
    done
    sleep 10
done

# ---------------------------------------------------------------------------
# Sample systemd unit (save as /etc/systemd/system/ring-frigate-push.service)
# ---------------------------------------------------------------------------
# [Unit]
# Description=Push Ring MP4s into Frigate one at a time
# After=network.target
#
# [Service]
# Type=simple
# ExecStart=/opt/ring-frigate/push_ring_mp4s.sh /opt/ring-frigate/cameras.conf
# Restart=on-failure
# User=frigate
#
# [Install]
# WantedBy=multi-user.target
#
# Then: sudo systemctl daemon-reload && sudo systemctl enable --now ring-frigate-push

