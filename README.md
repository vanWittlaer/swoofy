Shopware 6 Self-Hosting with Coolify
====================================

# About
This repository is a fully working **reference for self-hosting Shopware 6 on
[Coolify](https://coolify.io)** (a self-hosted PaaS), with the entire production **and**
staging stack provisioned as code with **[OpenTofu](https://opentofu.org)** (`infra/`) —
no clicking resources together in the Coolify UI, no hand-maintained `.env.local`.

Media is stored on **S3-compatible object storage** (not the local filesystem), so the app
containers stay stateless and horizontally scalable.

The Shopware application itself lives in the [`shopware/`](shopware/) subfolder; everything
around it is lifecycle tooling — local dev (ddev), the production image (`shopware/docker`),
the OpenTofu stack (`infra/`), and CI/CD (GitHub Actions + GitLab).

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

# The production image (shopware/docker)
Coolify runs a Docker image built from Shopware's `shopware/docker` package. Install it
inside the ddev web container with `composer require shopware/docker`; it generates
`shopware/docker/Dockerfile` — **do not hand-edit the generated stages**. This repo extends
it with a multi-stage split:

- **`final-prod`** — the base image plus custom nginx snippets (`shopware/docker/nginx`:
  real-IP from the proxy, redirects, a prohibitive `robots.txt`). Used for production.
- **`final-protected`** — `final-prod` plus HTTP basic-auth (`shopware/docker/nginx-basic-auth`).
  Used for staging/feature so non-prod hosts sit behind a login.

The image is **built in CI** (see [CI/CD](#cicd)) and pushed to a registry — the OpenTofu
stack deploys it by reference, it is not built on the server.

## Runtime topology
The stack is decomposed into separate Coolify resources, all managed by OpenTofu:

- **web** — the image above, nginx on port 8000.
- **worker/scheduler** — `infra/modules/shopware-stack/workers.tf`: a Coolify docker-compose
  service running two `messenger:consume` workers + one `scheduled-task:run` scheduler,
  reusing the web image. Workers drain gracefully on redeploy (SIGTERM + a grace period).
- **shell / backups** (optional) — an env-agnostic ops/maintenance sidecar image from the
  standalone [`shopware-ops-shell`](https://github.com/vanwittlaer/shopware-ops-shell) repo
  (Wolfi + bash + `shopware-cli` + rclone), **not built here**. See [Backups](#backups-optional).

# Provisioning the Coolify stack (OpenTofu)
The production and staging stacks are **Infrastructure-as-Code** in [`infra/`](infra/). One
module (`infra/modules/shopware-stack`) is instantiated once per environment and creates the
**web** app, the **worker/scheduler** service, **MariaDB**, **cache + session Redis**,
**RabbitMQ**, **Elasticsearch**, **Mailpit** (staging), the **S3** media wiring + CORS, and
the optional **backup** stack.

All application env — `DATABASE_URL`, `REDIS_*`, `MESSENGER_*` (RabbitMQ), `APP_SECRET`,
`INSTANCE_ID`, the `S3_*` keys, … — is **computed and injected by OpenTofu**, so there is no
`.env.local` to copy by hand.

## Prerequisites
- A running **Coolify v4** with the API enabled + a token, and a registered **server** (its UUID).
- A **private registry** holding the CI-built web image (ghcr.io / GitLab registry).
- **S3 buckets** for media (the public bucket must serve objects public-read); plus a backup
  bucket if backups are enabled.
- **OpenTofu ≥ 1.7** — baked into the ddev web container, so run `tofu` from `ddev ssh`.

## Apply
```bash
cd infra
cp secrets.auto.tfvars.example secrets.auto.tfvars   # fill in the few secrets you own
tofu init
tofu fmt -recursive && tofu validate
tofu apply -var-file=production.tfvars -var-file=staging.tfvars
```

The only secrets you provide (in the git-ignored `secrets.auto.tfvars`) are `server_uuid`,
`app_secret`, `instance_id`, `rabbitmq_password`, the S3 access keys, `mailer_dsn`, and — for
staging — `mailpit_ui_auth` (and the backup-bucket keys when backups are on). **Coolify
generates the DB/Redis passwords.** Per-environment **non-secret** settings (domains, image
tags, feature toggles, DB/Redis tuning) live in `production.tfvars` / `staging.tfvars`.

State is a **local backend** (`infra/tofu.tfstate`) — fine for a single operator; swap for a
remote, locked backend for a team. See [`infra/README.md`](infra/README.md) for the full
runbook and [`infra/FINDINGS.md`](infra/FINDINGS.md) for the provider/Coolify quirks.

## One-time manual steps OpenTofu can't express
- **`chown` the log dir** on the host so the container user (UID 82) can write:
  `mkdir -p /data/shopware/<env>/var/log && chown -R 82:82 /data/shopware/<env>/var/log`.
- **DB / Redis tuning** — set `my.cnf` / `redis.conf` in the Coolify UI; the current Coolify
  version rejects the provider's extended-fields update (see FINDINGS). The intended values
  live in the `mariadb_conf` / `redis_conf` tfvars, e.g. for MariaDB:
  ```
  [mysqld]
  default-time-zone='+00:00'
  group_concat_max_len=320000
  innodb_buffer_pool_size=1G
  sql_mode=STRICT_TRANS_TABLES,NO_ZERO_IN_DATE,NO_ZERO_DATE,ERROR_FOR_DIVISION_BY_ZERO,NO_ENGINE_SUBSTITUTION
  ```
  Redis cache: `appendonly no` / `save ""` / `maxmemory-policy volatile-lru`.
  Redis session: `appendonly yes` / `maxmemory-policy allkeys-lru` (must not evict sessions).
- **Build the Elasticsearch indices** in every env with `enable_elasticsearch = true`:
  `bin/console es:index` (storefront) + `bin/console es:admin:index` (admin), then redeploy
  the workers. Until built, search falls back to the DB, so nothing 500s.
- **Staging basic-auth** — create the `.htpasswd` on the host (bind-mounted into the web app
  at `/var/www/auth`), so the hash never enters the repo or image:
  ```bash
  mkdir -p /data/shopware/staging/auth
  htpasswd -nbB <user> '<password>' > /data/shopware/staging/auth/.htpasswd
  chown -R 82:82 /data/shopware/staging/auth
  ```
- **DNS** — point the storefront (and the staging Mailpit) domains at the server.

## Backups (optional)
Scheduled backups (`infra/modules/shopware-stack/backup.tf`) are toggled per-env via
`enable_backup`. The service runs the [`shopware-ops-shell`](https://github.com/vanwittlaer/shopware-ops-shell)
image idle; Coolify **Scheduled Tasks** `exec` `bin/backup-db.sh` (DB dump via
`shopware-cli project dump`) and `bin/backup-s3.sh` (offsite S3 mirror) into it on cron.
Point `backup_image` / `backup_image_tag` at the published image and set the backup-bucket
coordinates/credentials; see `infra/README.md` for schedules and bucket configuration.

# First deploy: seeding data
`tofu apply` provisions an **empty** stack — a fresh MariaDB and empty S3 buckets (the buckets
themselves are a prerequisite; OpenTofu only manages their CORS). Two ways to get to a working shop:

## a) Fresh install (from scratch)
The first deploy's post-deploy command runs the Shopware deployment-helper, which installs a
fresh system on an empty database — schema + migrations + `asset:install` + theme compile — and
writes the assets and compiled theme straight into the **public S3 bucket**. If the helper isn't
configured to auto-install, exec into the web container once:
```bash
vendor/bin/shopware-deployment-helper run     # installs when the DB is empty, otherwise migrates
# or explicitly:  bin/console system:install --basic-setup
bin/console user:create <admin> --admin       # create an admin login
```
Nothing to pre-seed in S3 — Shopware populates it.

## b) Import an existing installation
First match the source's Shopware version to this repo's `composer.lock` (up/downgrade the source
if needed), then bring over **both** the database and the media.

**Database** — dump the source and load it into the new MariaDB. Reach it over an SSH tunnel to
`mariadb_public_port`, or run the import from a maintenance/shell container on the server:
```bash
shopware-cli project dump --output dump.sql.gz ...   # (or mysqldump on the source)
zcat dump.sql.gz | mysql -h 127.0.0.1 -P <mariadb_public_port> -u shopware -p shopware
bin/console database:migrate --all                   # align the schema to the deployed version
# rewrite the sales_channel_domain rows to the new prod/staging URLs, then:
bin/console cache:clear
```
(The ddev `post-import-db` hook does the same domain rewrite locally — mirror it here.)

**Filesystem (media → S3)** — the media must live in the new buckets under Shopware's key layout
(mind the in-bucket prefix `S3_ROOT_PREFIX = <env>/`). From a local-disk source, sync it up; from
an existing S3 source, sync bucket→bucket:
```bash
rclone sync ./public/media     <remote>:swoofy-public/<env>/media
rclone sync ./public/thumbnail <remote>:swoofy-public/<env>/thumbnail
rclone sync ./private/...       <remote>:swoofy-private/<env>       # private assets, if any
bin/console theme:compile
bin/console media:generate-thumbnails                               # optional, if not synced
```
The ddev media proxy (`.ddev/nginx/media.conf`) is a **local-dev** convenience only — production
serves media from S3, so it must actually be uploaded there.

# CI/CD
Two equivalent pipelines **build the image → trigger a Coolify deploy webhook**, keyed by branch:

| Branch       | Environment | GitHub Actions (primary)  | GitLab (alt)      |
|--------------|-------------|---------------------------|-------------------|
| `main`       | prod        | build + deploy on push    | manual            |
| `develop`    | staging     | build + deploy on push    | manual            |
| `feature/**` | staging     | build only                | build only        |

- **GitHub** (`.github/workflows/ci-cd.yml`) is primary and runs automatically on push,
  pushing images to **ghcr.io**. `main` builds the `final-prod` image, `develop`/`feature`
  the `final-protected` (basic-auth) image.
- **GitLab** (`.gitlab-ci.yml`) is an equivalent manual alternative, pushing to the GitLab
  registry.
- **Post-deploy command** on the server:
  `vendor/bin/shopware-deployment-helper run --skip-theme-compile -n`

# Reference: management access
Keep the host firewall to **22 / 80 / 443** only. Internal services are reached over an SSH
tunnel, not public ports:

- **MariaDB** — host port set by `mariadb_public_port` (tfvars); tunnel to it for a SQL client.
- **RabbitMQ management** — host port set by `rabbitmq_mgmt_port`; tunnel to `127.0.0.1:<port>`
  to reach the management UI (AMQP 5672 stays internal).
