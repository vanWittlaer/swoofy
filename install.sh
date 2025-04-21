#!/usr/bin/env bash

# What it does:
# - Creates a local Shopware installation using the Symfony Flex template for local development of client projects
# - Prerequisites: ddev installed on your machine, see https://ddev.com/get-started/
#
# How to use:
# - create a project folder
# - copy this file into the project folder
# - chmod +x install.sh
# - ./install.sh

set -e

echo "Config ddev project (remember to adjust php and nodejs versions to your Shopware release!) ..."
ddev config --project-type=php --disable-settings-management --docroot=shopware/public \
        --web-working-dir=/var/www/html/shopware --composer-root=shopware \
        --database=mysql:8.0 --php-version=8.3 --nodejs-version=22 --webserver-type=nginx-fpm \
        --web-environment-add="DATABASE_URL=mysql://db:db@db:3306/db,MAILER_DSN=smtp://localhost:1025?encryption=&auth_mode=,APP_URL=\${DDEV_PRIMARY_URL},APP_DEBUG=1,APP_ENV=dev"

ddev start

echo "Composer create-project shopware ..."
ddev exec "cd /var/www/html && rm -rf shopware/ && composer create-project shopware/production shopware -n"

echo "Installing Shopware ..."
ddev exec bin/console system:install --basic-setup --shop-locale=de-DE

