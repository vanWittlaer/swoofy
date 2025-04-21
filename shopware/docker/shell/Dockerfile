FROM cgr.dev/chainguard/wolfi-base:latest

COPY --from=mysql:latest /usr/bin/mysqldump /usr/local/bin/mysqldump
COPY --from=shopware/shopware-cli:bin  /shopware-cli /usr/local/bin/shopware-cli

RUN apk add --no-cache \
    bash \
    libstdc++ \
    mysql-client \
    openssh-client \
    php-8.3 \
    rclone \
    rsync

COPY bin/ /var/www/html/bin/
WORKDIR /var/www/html
