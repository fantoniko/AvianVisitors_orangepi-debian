FROM python:3.11-slim-bookworm

# Chromium is used only to render the existing live collage; PocketFrame then
# handles EXIF rotation, grayscale conversion, and its final screen size.
RUN python -m pip install --no-cache-dir --upgrade pip \
  && python -m pip install --no-cache-dir Pillow==11.1.0 playwright==1.49.1 \
  && python -m playwright install --with-deps chromium

COPY frame /srv/publisher/frame
COPY platforms/split-web-host/docker/pocketframe-loop.sh /usr/local/bin/avian-pocketframe-loop
RUN chmod 0755 /usr/local/bin/avian-pocketframe-loop

WORKDIR /srv/publisher/frame
ENTRYPOINT ["/usr/local/bin/avian-pocketframe-loop"]
