FROM caddy:2-alpine

COPY platforms/split-web-host/docker/Caddyfile /etc/caddy/Caddyfile
