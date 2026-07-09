FROM alpine:3.20

COPY avian /image-app/avian
COPY platforms/split-web-host/docker/app-init.sh /usr/local/bin/avian-app-init
RUN chmod 0755 /usr/local/bin/avian-app-init

CMD ["/usr/local/bin/avian-app-init"]
