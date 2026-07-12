FROM php:8.3-fpm-alpine

RUN mv "$PHP_INI_DIR/php.ini-production" "$PHP_INI_DIR/php.ini" \
  && printf '[www]\nclear_env = no\npm = ondemand\npm.max_children = 2\npm.process_idle_timeout = 10s\npm.max_requests = 500\n' \
    > /usr/local/etc/php-fpm.d/zz-avian-env.conf

WORKDIR /srv/app
