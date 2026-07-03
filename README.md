Shopware 6 Self-Hosting with Coolify
====================================
# About
This repository provides a simple though fully working example
for a self-hosted Shopware 6 instance using Coolify as a self-hosted 
PaaS.

Note this simple setup stores all media files on the local filesystem.
This is not recommended for production. Instead, S3 should be used
for these.

# Local Setup
Use ddev, devenv or Dockware to create a local environment.

## ddev Setup
This repo provides a ddev configuration that is setup to run with
nginx-fpm, and already has the admin and storefront watchers
provisioned. The actual Shopware code is in the `shopware`
subfolder.

Note the definition of the environment variables has been moved
to a file `.env.dev`. The only env variable set in .ddev/config.yml
is APP_ENV.

Further, you need a database from your system that matches your
local Shopware version (if in doubt, check the composer.lock file).
Should you have a different version on your server, you need to
up- or downgrade your local version first, using composer.

Import your database locally with the following command from your
local terminal:

`zcat < your-db-dump.sql.gz | ddev import-db` 

The nginx proxy definitions in `.ddev/nginx/media.conf` will route
any media request that can not be served locally from a remote
server. Point it to your server 
(the one where you cloned the database from) and there is no need
to clone your media files from the server to your local installation.

### Setup without a database
Run `ddev exec vendor/bin/shopware-deployment-helper run` to create
an initial system. The default admin credentials are admin/shopware.

### ddev Addons
Regular DDEV addons have been added for Redis, RedisCommander, RabbitMQ 
and ElasticSearch. 

All addons follow their respective default configurations, 
with the exception of Redis. Note the updated configuration in
`.ddev/redis/redis.conf`.

# Preparation for Coolify
## shopware/docker
Coolify works with a Docker container that is created based
on Shopware's shopware/docker project. To install shopware/docker
run this command inside your ddev web container:

`composer require shopware/docker`

The command will create a subfolder `shopware/docker` that contains
the Dockerfile provided Shopware. Do not modify this file.

## Worker
The worker/scheduler services are defined and deployed by the OpenTofu stack
(`infra/modules/shopware-stack/workers.tf`) as a Coolify docker-compose service:
two `messenger:consume` workers + one `scheduled-task:run` scheduler, reusing the
web image.

## Shell
The Shopware container image ships no bash, no `mysqldump` and no S3 client, so
backups/maintenance run in a small **ops/maintenance sidecar** image. It lives in its
own standalone, generally-available repo — **[`shopware-ops-shell`](https://github.com/vanwittlaer/shopware-ops-shell)**
(Wolfi + bash + `shopware-cli` + rclone) — and is consumed here as a published
image (`ghcr.io/vanwittlaer/shopware-ops-shell`), not built from this repo. See the
[backup](#backup-optional) section below for how the OpenTofu stack wires it.

## Pipeline
A gitlab pipeline is used for the build and deploy steps. defined
in detail in `.gitlab-ci.yml`.

# Coolify Server Setup
## Admin Server
Check in with Coolify's cloud, or create your own Coolify admin server.
## App Server
Get a cloud server from Hetzner or the likes. Use a Ubuntu distribution.

## Persistent Storage
## .env.local
```dotenv
APP_DEBUG=0
APP_URL=https://example.com
#
# performance
#
APP_URL_CHECK_DISABLED=1
BLUE_GREEN_DEPLOYMENT=0
SHOPWARE_CACHE_ID=some-simple-string
SQL_SET_DEFAULT_SESSION_VARIABLES=0
#
# set because behind Coolify traefik
TRUSTED_PROXIES=127.0.0.1/0
#
# credentials
#
DATABASE_URL=<copy from your mysql resource>
#
REDIS_CACHE_URL=<copy from your redis cache resource>
#
REDIS_SESSION_URL=<copy from your redis session resource>
#
MESSENGER_TRANSPORT_DSN=amqp://user:password@rabbitmq-container:5672/%2f/async
MESSENGER_TRANSPORT_FAILURE_DSN=amqp://user:password@rabbitmq-container:5672/%2f/failed
MESSENGER_TRANSPORT_LOW_PRIORITY_DSN=amqp://user:password@rabbitmq-container:5672/%2f/low_priority
#
# secrets
#
INSTANCE_ID=<your unique instance id>
APP_SECRET=<your app secret>
#
# backup bucket (offsite, different location than the source S3) — used by bin/backup-db.sh & bin/backup-s3.sh
#
S3_BACKUP_BUCKET=<backup bucket name>
S3_BACKUP_REGION=<e.g. fsn1>
S3_BACKUP_DOMAIN=<e.g. https://fsn1.your-objectstorage.com>
S3_BACKUP_PATH=<in-bucket prefix, e.g. production>
S3_BACKUP_ACCESS_KEY_ID=<backup bucket credentials>
S3_BACKUP_SECRET_ACCESS_KEY=
DB_BACKUPS_TO_KEEP=60
S3_BACKUP_RETAIN_DAYS=30
```
## Resources
### webserver
To execute the post-deployment tasks (like plugin updates, theme compile, migrations etc.) add this to the 
post-deployment command:

`vendor/bin/shopware-deployment-helper run --skip-theme-compile -n`
### worker
Workers drain gracefully on redeploy without any shutdown script: on SIGTERM, Symfony Messenger
finishes the in-flight message and exits, so a stop signal + grace period is all that's needed.
The OpenTofu stack wires this on the worker/scheduler service
(`infra/modules/shopware-stack/workers.tf`: `stop_signal: SIGTERM` + `stop_grace_period: 120s`).
### backup (optional)
Scheduled backups are also defined and deployed by the OpenTofu stack
(`infra/modules/shopware-stack/backup.tf`), toggled per-env via `enable_backup`.
The service runs the env-agnostic **ops/maintenance sidecar** image idle
(`tail -f /dev/null`) — built and published by its own repo
([`shopware-ops-shell`](https://github.com/vanwittlaer/shopware-ops-shell)), pointed at
here via the `backup_image` / `backup_image_tag` tfvars. Coolify Scheduled Tasks `exec`
`bin/backup-db.sh` and `bin/backup-s3.sh` into the running container on cron — the former
dumps the database (via `shopware-cli project dump`) to the backup bucket, the latter
mirrors the S3 buckets offsite. See `infra/README.md` for the schedules and bucket
configuration.
### mysql
#### Image
I have successfully tested with `mysql:8.0.40-debian`. 
(Note the debian flavour comes with the `mysqlbinlog` command installed.)
#### Ports Mappings
`4306:3306` only needed if you plan to ssh-tunnel to the database, leave it unfilled otherwise.
#### Custom Mysql Configuration
```text
[mysqld]
default-time-zone='+00:00'
group_concat_max_len=320000
innodb_buffer_pool_size=1G
sql_mode=STRICT_TRANS_TABLES,NO_ZERO_IN_DATE,NO_ZERO_DATE,ERROR_FOR_DIVISION_BY_ZERO,NO_ENGINE_SUBSTITUTION
```
### redis for Cache
#### Custom Redis Configuration
```text
appendonly no
save ""
maxmemory-policy volatile-lru
```
### redis for Session
#### Custom Redis Configuration
```text
appendonly yes
maxmemory-policy allkeys-lru
```

### RabbitMQ
#### RabbitMQ Management
In the Configuration, click `Edit Compose File` and add `15672:15672`
to the ports section. Restart.
Create an ssh tunnel to 127.0.0.1:15672 to access RabbitMQ Management
from your local machine.