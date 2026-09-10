# ring2frigate

Feeds Ring doorbell/camera MP4 clips (delivered as files, not live streams)
into Frigate for object detection, audio detection, and recording — without
installing anything on the Frigate host, and without Frigate needing to know
the source is a file rather than a real camera.

## How it works

Frigate expects a continuous live stream per camera. Ring gives you finished
MP4 files after the fact. This bridges the two:

1. Something (Ring integration, Home Assistant, etc.) drops an MP4 into a
   per-camera watch directory.
2. A small container (`ring2frigate`) notices the new file and pushes it
   into Frigate's bundled **go2rtc** RTSP server via `ffmpeg`, as if it were
   a live camera briefly coming online.
3. Frigate — configured with a normal camera entry pointing at that go2rtc
   stream — captures it exactly like any other camera: runs detection, audio
   analysis, and writes a recording segment.
4. Once the push finishes, the file is renamed to `<name>.mp4.done` so it's
   never reprocessed.

```
Ring MP4 file  →  ring2frigate container  →  go2rtc (on Frigate host)  →  Frigate camera
 (dropped into      (ffmpeg push over            (rtsp://host:8554/<cam>)   (detect/record/audio)
  watch dir)          RTSP, TCP)
```

## Repo layout

| File | Purpose |
|---|---|
| `cameras.conf` | Single source of truth: camera name → watch directory. Used by both the pusher and the Frigate config generator. |
| `push_ring_mp4s.sh` | Watches each camera's directory and pushes new MP4s into go2rtc. |
| `generate_frigate_config.py` | Generates the Frigate `cameras:` and `go2rtc:` YAML blocks from `cameras.conf`, so you never hand-write config for many cameras. |
| `Dockerfile` | Builds the pusher image (Debian + ffmpeg + inotify-tools). |
| `docker-compose.yml` | Optional compose file with network-mode notes for different Frigate deployment setups. |

## One-time setup

### 1. Declare the streams in go2rtc

go2rtc will **not** accept a push to an arbitrary/undeclared path — the
stream name has to exist in its config first, with an empty source, before
anything can publish to it. Add this to Frigate's `config.yml`:

```yaml
go2rtc:
  streams:
    ring_front_door:
    ring_house_rear_doors:
    ring_bee_hut_house:
    # ... one empty entry per camera name
```

or use generate_frigate_config.py below to generate the go2rtc: section

### 2. Add the camera entries to Frigate

Fill in `cameras.conf` with your real camera names and directories, then
generate the config block:

```bash
python3 generate_frigate_config.py cameras.conf > ring_cameras.yaml
```

Paste the output into `config.yml` under the top-level `cameras:` and `go2rtc:` keys. Each
camera's `ffmpeg.inputs[0].path` points at
`rtsp://127.0.0.1:8554/<camera_name>` — `127.0.0.1` is correct here because
this file lives on the Frigate host, talking to its own local go2rtc.

Restart Frigate to pick up both changes:
```bash
docker restart frigate
```

### 3. Build and run the pusher

On the machine that will actually watch the drop directories (does **not**
need to be the Frigate host):

```bash
docker build -t ring2frigate .

docker run -d \
  --name ring2frigate \
  --restart unless-stopped \
  -e RTSP_HOST=192.168.0.97 \
  -e RTSP_PORT=8554 \
  -e LOG_DIR=/var/log/ring-frigate \
  -e MIN_PUBLISH_SECONDS=45 \
  -v /path/to/cameras.conf:/config/cameras.conf:ro \
  -v /path/to/media:/media/ring \
  -v /path/to/logs:/var/log/ring-frigate \
  ring2frigate
```

- `RTSP_HOST` / `RTSP_PORT` — where Frigate's go2rtc is reachable. If the
  pusher and Frigate are the *same* Docker host, `--network container:frigate`
  lets you leave this as `127.0.0.1` instead (see `docker-compose.yml`).
- The **media directory on the host must contain a subfolder per camera**
  matching the paths in `cameras.conf` exactly (e.g.
  `/path/to/media/ring_front_door/`). Ring deliveries (or whatever drops the
  files) need to write into these host paths.
- Use a **durable path**, not `/tmp` — `/tmp` can be cleared on reboot or by
  periodic cleanup, silently losing any clip that hasn't been processed yet.

## Configuration reference

| Env var | Default | Purpose |
|---|---|---|
| `RTSP_HOST` | `127.0.0.1` | Host/IP where go2rtc's RTSP server is listening. |
| `RTSP_PORT` | `8554` | go2rtc RTSP port. |
| `LOG_DIR` | `/var/log/ring-frigate` | Where per-camera logs are written. |
| `MIN_PUBLISH_SECONDS` | `45` | Minimum time to keep the stream alive per file (see below). `0` disables this — single real-time pass, no looping. |

### Why `MIN_PUBLISH_SECONDS` exists

Frigate's own ffmpeg only (re)connects to go2rtc on its own retry cycle,
which can leave 10–30+ second gaps between connection attempts. A clip only
a few seconds long can finish publishing and disappear again before Frigate
ever tries to connect during that window — silently missed, no error
anywhere. To make the overlap reliable, the pusher loops the source clip
**inside a single continuous ffmpeg process** (`-stream_loop`) for at least
this many seconds, so there's a wide, continuous window for Frigate to catch
it.

This has to be one continuous process, not repeated separate pushes — an
earlier version restarted ffmpeg per loop, which reset RTSP timestamps to
zero each time. Frigate's recorder correctly refused those out-of-order
frames, producing technically-valid but nearly frozen recordings (observed
as ~0.23 fps instead of the source's real frame rate) and Review items that
were listed but wouldn't play ("No preview found"). `-stream_loop` avoids
this by keeping timestamps monotonically increasing throughout.

## Troubleshooting

**Push fails with `method SETUP failed: 461 Unsupported transport`**
ffmpeg defaulted to UDP; go2rtc only accepts TCP for incoming publishes.
Already handled in the script (`-rtsp_transport tcp`) — if you see this,
you're likely running an older copy of `push_ring_mp4s.sh`.

**Push fails with `Broken pipe`, and Frigate logs show
`method DESCRIBE failed: 404 Not Found`**
The stream name isn't declared in go2rtc's config. See setup step 1 above —
go2rtc needs an empty `streams:` entry for the camera before anything can
publish to it.

**Push completes cleanly, but the camera never shows a recording, and
Review items say "No preview found" and won't open**
Almost always the race-condition problem described above — the publish
window was too short for Frigate's retry cycle to catch it. Increase
`MIN_PUBLISH_SECONDS`.

**Recording exists but `ffprobe` shows a very low average fps
(e.g. `0.23 fps`)**
Timestamp discontinuity from restarting ffmpeg mid-clip. Confirm you're
running the current script — it publishes each file as a single continuous
`-stream_loop` process, not multiple separate ffmpeg invocations.

**A camera's files are never picked up at all**
Check that the camera name is *identical* — same spelling, same
`ring_` prefix or lack thereof — across `cameras.conf`, the host media
subdirectory, and Frigate's `config.yml`. A one-character mismatch means
the watcher is watching a directory nothing is ever copied into.

**Confirming which hour folder to check on the Frigate side**
Frigate's recording folders are UTC-based. Run `docker exec frigate date`
to see what the container itself considers "now" before hunting for a
specific hour folder under `/media/frigate/recordings/`.

## Clean Up

After successful processing of an mp4 video file that was dropped into the watched directories it is renamed to .mp4.done - however
there is currently no cleanup process built into the script and the expectation is that whichever process drops the files will handle
cleanup.

This could be as simple as a crontab entry with a `find /tmp/ring2frigate -type f -name "*.mp4.done" -mmin +1440 -delete` command.

## Useful one-off checks

```bash
# Tail a camera's push log
tail -f /path/to/logs/ring_front_door.log

# Confirm go2rtc/Frigate can be reached from the pusher machine
telnet 192.168.0.88 8554

# List recording segments actually on disk for a camera/hour
docker exec frigate ls -la /media/frigate/recordings/$(docker exec frigate date -u +%Y-%m-%d)/<hour>/ring_front_door/

# Sanity-check a recorded segment's real frame rate/codecs
docker exec frigate ffprobe /media/frigate/recordings/<date>/<hour>/ring_front_door/<segment>.mp4
```

## Scaling to more cameras

1. Add a line to `cameras.conf`.
2. Create the matching subdirectory under the media mount.
3. Re-run `generate_frigate_config.py` and paste the new camera's block into
   `config.yml`, plus an empty entry under `go2rtc.streams`.
4. `docker restart frigate`.
5. No pusher rebuild needed — it re-reads `cameras.conf` on each container
   start, so just recreate the `ring2frigate` container.

