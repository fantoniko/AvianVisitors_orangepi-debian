FROM caddy:2-alpine

COPY platforms/split-web-host/docker/Caddyfile /etc/caddy/Caddyfile
COPY platforms/split-web-host/docker/web-entrypoint.sh /usr/local/bin/avian-web-entrypoint
COPY avian/frontend /srv/app/avian/frontend
COPY avian/api /srv/app/avian/api
COPY avian/assets/favicon.png /srv/app/avian/assets/favicon.png
RUN chmod 0755 /usr/local/bin/avian-web-entrypoint

ENTRYPOINT ["/usr/local/bin/avian-web-entrypoint"]
CMD ["caddy", "run", "--config", "/etc/caddy/Caddyfile", "--adapter", "caddyfile"]
