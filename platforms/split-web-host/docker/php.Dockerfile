FROM php:8.3-fpm-bookworm

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    libcurl4-openssl-dev \
    libsqlite3-dev \
  && docker-php-ext-install curl pdo_sqlite sqlite3 \
  && rm -rf /var/lib/apt/lists/*

RUN printf '[www]\nclear_env = no\n' > /usr/local/etc/php-fpm.d/zz-avian-env.conf

WORKDIR /srv/app
