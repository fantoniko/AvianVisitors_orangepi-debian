FROM alpine:3.20

ARG SOURCE_COMMIT=unknown
COPY avian /image-app/avian
COPY platforms/split-web-host/docker/app-init.sh /usr/local/bin/avian-app-init
RUN printf '%s\n' "$SOURCE_COMMIT" > /image-app/SOURCE_COMMIT \
  && chmod 0755 /usr/local/bin/avian-app-init

CMD ["/usr/local/bin/avian-app-init"]
