FROM alpine:3.20

COPY . /image-app

CMD ["sh", "-lc", "cp -a /image-app/. /srv/app/"]
