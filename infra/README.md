# Shopware-on-Coolify OpenTofu Spike

Stand up a representative Shopware stack on an existing Coolify v4 instance with native
OpenTofu + the `coolify-terraform/coolify` provider, across **production + staging**, to
decide whether a `coolshop-cli` wrapper is worth building. The stack is up and working;
the provider/Coolify quirks discovered along the way are in `FINDINGS.md`.

## What gets created (per environment)

| Resource | tofu type | Notes |
|---|---|---|
| `web` | `coolify_application_docker_image` | nginx+php-fpm on :8000, storefront domain, health check `/api/_info/health-check`, post-deploy runs the deployment-helper (install/migrate). Staging runs the `final-protected` image (HTTP basic-auth) + a `.htpasswd` bind mount |
| `workers` | `coolify_service` (`docker_compose_raw`) | **one service, 3 containers**: `worker-1`, `worker-2` (`messenger:consume`), `scheduler` (`scheduled-task:run`) |
| `mariadb`, `redis-cache`, `redis-session` | `coolify_database_*` | DSNs read from each resource's computed `internal_db_url`; Symfony lock uses the DB |
| `rabbitmq`, `elasticsearch` | `coolify_service` (`docker_compose_raw`) | internal-only; elasticsearch per-env via `enable_elasticsearch` (on for prod + staging) |
| `mailpit` | `coolify_application_docker_image` | per-env via `enable_mailpit` (staging on, prod off → real SMTP); web UI on `mailpit_domain`, gated by `MP_UI_AUTH` (`mailpit_ui_auth`) |
| `backup` | `coolify_service` (`docker_compose_raw`) + 2× `coolify_scheduled_task` | idle `shopware-ops-shell` sidecar, cron-`exec`'d; per-env via `enable_backup` (on for prod + staging) |

The private/public **filesystems are on S3** (`shopware/config/packages/shopware.yaml`); the
`S3_*` env vars are fanned out to every process, and bucket **CORS** is managed via the AWS
provider pointed at the S3 endpoint (`cors.tf`). The provider has no shared-variable
resource, so the shared env (`local.shared_env`) is fanned out per resource.

## Layout

- `main.tf` — instantiates `modules/shopware-stack` twice (production + staging).
- `modules/shopware-stack/` — the stack: `apps.tf` (web), `workers.tf` (workers service),
  `databases.tf`, `services.tf` (rabbitmq/elasticsearch/mailpit), `backup.tf` (optional backup
  service + scheduled tasks), `env.tf`, `storage.tf` (web `var/log` + staging `.htpasswd` bind
  mounts), `locals.tf` (shared env, DSNs). `cors.tf` lives at root.
- `production.tfvars` / `staging.tfvars` — per-env **non-secret** settings.
- `secrets.auto.tfvars` — **git-ignored** secrets (see below).

## Prerequisites

- A running **Coolify v4** instance with the **API enabled** + a token, and a **server**
  registered in it (you need its UUID).
- A **private registry** with the built `web` image. NB: `config/packages/*.yaml` (S3,
  trusted_proxies, monolog) is **baked into the image at build time** — a config change
  needs an image rebuild, not just a tofu apply. The build stage must be PHP 8.4
  (`shopware/docker/Dockerfile`) to match the lock/runtime.
- **S3 buckets** already created (public bucket must serve objects **public-read**).
- **OpenTofu** — no local install needed; it's baked into the **ddev web container** via
  `.ddev/web-build/Dockerfile.opentofu` (the official `install-opentofu.sh`, deb method). Run
  `tofu` from inside ddev (`ddev ssh`, then `cd infra`). That container also provides the
  `curl` the `connect_to_docker_network` local-execs shell out to.

## Setup

Run everything below **inside the ddev web container** (`ddev ssh`), where `tofu` lives:

```bash
cd infra
cp secrets.auto.tfvars.example secrets.auto.tfvars   # fill in real values
tofu init
tofu fmt -recursive && tofu validate
```

### `secrets.auto.tfvars` (git-ignored)

Coolify connection (`coolify_endpoint` / `coolify_token` / `server_uuid`) plus per-env
`secrets_production` / `secrets_staging`. Coolify generates the DB/Redis passwords (consumed
via `internal_db_url`), and we set the RabbitMQ password ourselves, so the values you own are:

- `server_uuid` — the Coolify **server** each env deploys onto (an existing server's id, not a
  generated secret). Same UUID for both = co-located; different UUIDs = prod and staging split
  across servers.
- `app_secret`, `instance_id`, `rabbitmq_password` — generate once with `openssl rand -hex 16`,
  keep **stable** across deploys (distinct prod vs staging).
- `s3_access_key_id` / `s3_secret_access_key` — object-storage credentials.
- `mailer_dsn` — production SMTP DSN (defaults to `null://null`; staging ignores it and uses
  Mailpit).
- `mailpit_ui_auth` — (staging) basic-auth for the Mailpit web UI (`MP_UI_AUTH`), space-separated
  `user:password`. Empty ⇒ the UI is open — set it, since Mailpit gets a public domain.
- `s3_backup_access_key_id` / `s3_backup_secret_access_key` — backup-bucket credentials, required
  when `enable_backup = true` (Hetzner keys are project-wide, so these may equal the `s3_*` pair).

### Per-environment settings (`*.tfvars`)

Env-specific knobs live in the `production` / `staging` objects: `web_image*`, `web_domain`,
`s3`, the Symfony env controls **`app_env`** (`prod` / `stage`) / **`app_debug`** /
**`monolog_log_level`**, the infra toggles **`enable_elasticsearch`** / **`enable_mailpit`** /
**`enable_backup`** (+ the **`backup`** object: bucket, region, domain, path, schedules), and —
staging only — **`mailpit_domain`** (the Mailpit web-UI FQDN). Mail routing follows
`enable_mailpit` (staging → Mailpit, production → the secret DSN).
(`mariadb_public_port` / `rabbitmq_mgmt_port` are still literals in `main.tf` — a remaining
candidate to move into the per-env objects for uniformity.)

**Separate servers per environment.** Each env's Coolify server is its **`server_uuid` inside
the `secrets_production` / `secrets_staging` object** (git-ignored `secrets.auto.tfvars`) —
symmetric with the other per-env secrets. Point both at the same UUID to co-locate, or at
different UUIDs to run prod and staging on separate servers. One Coolify control plane (the
single `endpoint`/`token`) manages both — only the per-resource `server_uuid` differs, so no
provider aliasing is needed.

### Backup service

Scheduled backups (`modules/shopware-stack/backup.tf`) are gated per-env by **`enable_backup`**
(like `enable_elasticsearch` — on for both prod and staging). The service is a single-container
`docker_compose_raw` running the **env-agnostic ops/maintenance sidecar image** idle on
`tail -f /dev/null`. That image is **not built here** — it lives in its own standalone repo
([`shopware-ops-shell`](https://github.com/vanwittlaer/shopware-ops-shell)) and is referenced by
the root-level `backup_image` / `backup_image_tag` vars (one image tag serves both environments,
e.g. `ghcr.io/vanwittlaer/shopware-ops-shell:latest` — pin a released `vX.Y.Z` for production).

Coolify **Scheduled Tasks** `exec` the two backup scripts into that running container on cron:
`backup-db` (`bin/backup-db.sh`, DB dump via `shopware-cli project dump`) and `backup-s3`
(`bin/backup-s3.sh`, offsite S3 mirror). Default schedules are `0 2 * * *` / `30 2 * * *`
(staggered so the S3 mirror runs after the DB dump); override per env via **`backup.db_schedule`**
/ **`backup.s3_schedule`** in `production.tfvars` / `staging.tfvars`.

The backup bucket is a **separate bucket** (`swoofy-backup`). *Ideally* it would sit at a
different, offsite location than the source buckets — but the current tfvars point it at
**`hel1`**, the same object-storage location as the source (that's the only Hetzner location in
use here). So it protects against accidental deletion (separate bucket + rclone soft-deletes)
but **not** a location-wide outage; set `backup.s3_backup_region` / `s3_backup_domain` to a
different location if you have one. Its credentials (`s3_backup_access_key_id` /
`s3_backup_secret_access_key`) are **secrets** in the git-ignored `secrets.auto.tfvars`, not in
`*.tfvars` (Hetzner keys are project-wide, so they can be the same pair as `s3_*`).

## Apply

```bash
# both environments
tofu apply -var-file=production.tfvars -var-file=staging.tfvars

# production only (staging.tfvars still needed to satisfy the required var)
tofu apply -target=module.production -var-file=production.tfvars -var-file=staging.tfvars
```

### One-time manual steps (can't be expressed in the provider)

- **`chown` the log dir** on the Coolify host so the container user (UID 82) can write:
  `mkdir -p /data/shopware/<env>/var/log && chown -R 82:82 /data/shopware/<env>/var/log`.
- **DB tuning** (`mariadb_conf` / `redis_conf`) is disabled in `databases.tf` — Coolify 4.1.2
  rejects the provider's extended-fields update; set `my.cnf` / `redis.conf` in the Coolify UI.
- **Build the ES indices** in every environment where `enable_elasticsearch = true` (now prod
  **and** staging): after the deploy that wires Elasticsearch, run `bin/console es:index`
  (storefront) and `bin/console es:admin:index` (admin search), and redeploy the workers so
  they pick up the ES env. Until built, search falls back to the DB
  (`SHOPWARE_ES_THROW_EXCEPTION=0`), so nothing 500s in the meantime.
- **Staging basic-auth `.htpasswd`** — the staging `final-protected` image serves the storefront
  behind HTTP basic-auth, reading `/var/www/auth/.htpasswd` from a host bind mount
  (`basic_auth_host_path`, wired in `main.tf` to `<log_host_base>/staging/auth`). Create it on
  the host so the hash never enters the repo/image:
  `mkdir -p /data/shopware/staging/auth && htpasswd -nbB <user> '<pw>' > /data/shopware/staging/auth/.htpasswd && chown -R 82:82 /data/shopware/staging/auth`.

`connect_to_docker_network` (rabbitmq + workers + elasticsearch + backup reaching the shared
network) is handled automatically by `null_resource`s (the provider can't round-trip the flag).

### Env changes need a redeploy

`tofu apply` only writes env vars into Coolify's config — Coolify injects them at
**(re)deploy** time. After changing an env value, redeploy the affected `web` app / `workers`
service (Coolify UI **Redeploy**, or `POST /api/v1/deploy?uuid=…&force=true`). The
`coolify_envs_bulk` vars are write-only to the provider, so tofu re-pushes them every apply
and can't detect drift — always pair an env change with a manual redeploy.

## Teardown

```bash
tofu destroy -var-file=production.tfvars -var-file=staging.tfvars
```

Coolify may leave orphaned containers behind (they keep Traefik labels and can keep serving a
domain); remove them on the host with `docker rm -f` — see FINDINGS.

## State & outcome

State is a **local file** (`tofu.tfstate`, `backend "local"` in `versions.tf`) — fine for a
spike; swap for a remote, locked, encrypted backend before real production.

Because the state and the owned secrets live only on one machine, **keep a safe backup copy of
the git-ignored `secrets.auto.tfvars`** (e.g. in a password manager or offline vault). Losing
it means regenerating `app_secret` / `instance_id` and re-entering every credential. Consider
also stashing a periodic copy of **`tofu.tfstate`** off-machine: losing it doesn't lose the
infrastructure — the Coolify provider supports `tofu import`, so the stack can be re-adopted by
ID — but a copy spares you the tedious per-resource re-import. See `FINDINGS.md` for the full
provider/Coolify quirk log feeding the `coolshop-cli` go/no-go.
