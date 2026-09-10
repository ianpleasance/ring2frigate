#!/usr/bin/env python3
"""
Generates a Frigate `cameras:` YAML block from cameras.conf, so you don't
hand-write config for 20 cameras.

Usage:
    python3 generate_frigate_config.py cameras.conf > ring_cameras.yaml

Then paste the contents of ring_cameras.yaml into your main frigate.yml
under the top-level `cameras:` key (alongside your existing live-stream
cameras).

Each camera reads from rtsp://127.0.0.1:8554/<camera_name>, which is
go2rtc's built-in RTSP server (bundled with Frigate). The push script
(push_ring_mp4s.sh) publishes each Ring MP4 to that path once; Frigate
just sees it as a live camera that starts, plays, and goes quiet again.
"""
import sys

RTSP_HOST = "127.0.0.1"
RTSP_PORT = 8554

TEMPLATE = """  {name}:
    enabled: true
    ffmpeg:
      inputs:
        - path: rtsp://{host}:{port}/{name}
          roles:
            - detect
            - record
            - audio
    detect:
      enabled: true
      width: 1280
      height: 720
      fps: 5
    record:
      enabled: true
      retain:
        days: 7
        mode: all
      events:
        retain:
          default: 30
    objects:
      track:
        - person
        - car
        - cat
        - bird
        - bicycle
        - car
        - motorcycle
        - bus
        - horse
    audio:
      enabled: true
      listen:
        - bark
        - fire_alarm
        - alarm
        - smoke_detector
        - scream
        - speech
        - yell
        - meow
        - breaking
        - smash
        - glass
        - shatter
        - hiss
        - crying
        - vehicle
        - motor_vehicle
        - honk
        - toot
        - car_alarm
        - car_passing
        - tire_squaling
    live:
      stream_name: {name}
"""


def main(conf_path: str) -> None:
    names = []
    with open(conf_path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            name, _, _dir = line.partition(":")
            name = name.strip()
            if not name:
                continue

            names.append(name)

    print("cameras:")
    for name in names:
        print(TEMPLATE.format(name=name, host=RTSP_HOST, port=RTSP_PORT))

    print("go2rtc:")
    print("  rtsp:")
    print("    listen: :8554")
    print("  streams:")

    for name in names:
        print("    %s" % (name))


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("Usage: generate_frigate_config.py cameras.conf", file=sys.stderr)
        sys.exit(1)
    main(sys.argv[1])
