#syntax=docker/dockerfile:1.4

# pin versions
FROM ghcr.io/shopware/docker-base:8.4-nginx AS base-image
FROM ghcr.io/shopware/shopware-cli:latest-php-8.4 AS shopware-cli

# build

FROM shopware-cli AS build

ARG SHOPWARE_PACKAGES_TOKEN

ADD . /src
WORKDIR /src

ENV SHOPWARE_CACHE_ID=docker

RUN --mount=type=secret,id=composer_auth,dst=/src/auth.json \
    --mount=type=cache,target=/root/.composer \
    --mount=type=cache,target=/root/.npm \
    /usr/local/bin/entrypoint.sh shopware-cli project ci /src

# build final image

FROM base-image AS final-prod

ENV SHOPWARE_DISABLE_UPDATE_CHECK=1

COPY --from=build --chown=82 --link /src /var/www/html

RUN mkdir -p /var/www/html/var/log && mkdir -p /var/www/html/var/cache

USER root
RUN mkdir -p /etc/nginx/conf.d && chown -R www-data:www-data /etc/nginx/conf.d
USER 82

COPY --chown=82 ./docker/nginx /etc/nginx/conf.d

FROM final-prod AS final-protected

COPY --chown=82 ./docker/nginx-basic-auth /etc/nginx/conf.d