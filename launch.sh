# Build the image (run on 192.168.0.99)
#docker build -t ring2frigate .
# /path/to/ring-frigate

docker stop ring2frigate
docker rm ring2frigate
docker build -t ring2frigate .

mkdir -p /tmp/ring2frigate
mkdir -p /tmp/ring2frigate/logs

# Run it
docker run -d \
  --name ring2frigate \
  --restart unless-stopped \
  -e RTSP_HOST=192.168.0.97 \
  -e RTSP_PORT=8554 \
  -e LOG_DIR=/var/log/ring-frigate \
  -v /home/ian/ring2frigate/cameras.conf:/config/cameras.conf:ro \
  -v /tmp/ring2frigate:/media/ring \
  -v /tmp/ring2frigate/logs:/var/log/ring-frigate \
  ring2frigate

