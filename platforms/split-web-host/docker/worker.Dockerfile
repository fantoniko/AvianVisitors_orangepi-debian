FROM python:3.11-slim-bookworm

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    ca-certificates \
    libglib2.0-0 \
    libgl1 \
    libgomp1 \
  && rm -rf /var/lib/apt/lists/*

COPY avian/scripts/requirements.txt /tmp/avian-requirements.txt
RUN python -m pip install --no-cache-dir --upgrade pip wheel \
  && python -m pip install --no-cache-dir -r /tmp/avian-requirements.txt

COPY platforms/split-web-host/docker/worker-loop.sh /usr/local/bin/avian-worker-loop
RUN chmod 0755 /usr/local/bin/avian-worker-loop

WORKDIR /srv/app
ENTRYPOINT ["/usr/local/bin/avian-worker-loop"]
