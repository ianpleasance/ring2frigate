FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
        ffmpeg \
        inotify-tools \
        bash \
        coreutils \
        findutils \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY push_ring_mp4s.sh /app/push_ring_mp4s.sh
RUN chmod +x /app/push_ring_mp4s.sh

ENTRYPOINT ["/app/push_ring_mp4s.sh"]
CMD ["/config/cameras.conf"]
