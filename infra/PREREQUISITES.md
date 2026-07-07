# Prerequisites & one-time manual steps

Everything that must be true **around** `ddev coolify-bootstrap up` (the one-shot entry point;
`tofu apply` runs underneath it — see `README.md`) that the Coolify provider can't do for you.
Work top to bottom: [A] before the first run, [B] one-time manual steps after it (per
environment), [C] the recurring rule that applies to every later change.

Placeholders: `<env>` = `production` | `staging`; `<log_host_base>` = your `log_host_base`
tfvar (e.g. `/data/shopware`); container user is **UID 82** (the Shopware base image user).

---

## [A] Before the first run

### Control plane & tooling
- [ ] **Coolify v4** instance running, **API enabled**, with an **API token** (Security → API
      Tokens). Scope it as narrowly as the apply flow allows — a `root` token can read every
      SSH key and secret Coolify holds, so avoid `root` unless a narrower scope fails.
- [ ] A **server registered** in Coolify for each environment; note its **`server_uuid`**.
      Same UUID for both envs = co-located; different = prod/staging on separate hosts.
- [ ] **ddev running** (`ddev start`) — OpenTofu ≥ 1.7 is baked into the web container
      (`.ddev/web-build/Dockerfile.opentofu`); `ddev coolify-bootstrap up` runs it for you, you
      never invoke `tofu` yourself.

### Host sizing
- [ ] Enough **RAM + swap** on each server. The full stack (web + workers + MariaDB + 2×Redis +
      RabbitMQ + Elasticsearch, ×N envs if co-located) is memory-hungry — ES alone runs well
      past its `-Xmx512m` heap, and a rolling deploy briefly runs **two** web containers. A host
      with too little RAM and **no swap** will OOM-kill ES mid-deploy and drop the SSH the
      deploy runs over. Provision swap and size for the peak, not the idle.

### Image & registry
- [ ] A **private registry** holding the built **`web` image**, referenced by `web_image` /
      `web_image_tag` in `*.tfvars`. The image must exist **before** apply — tofu deploys it,
      it doesn't build it (CI does).
- [ ] Built on **PHP 8.4** (`shopware/docker/Dockerfile`), matching `composer.lock`.
- [ ] Remember: `config/packages/*.yaml` (S3, trusted_proxies, monolog) is **baked into the
      image at build time** — a config change needs an **image rebuild**, not just a `tofu apply`.
- [ ] (Backup enabled) the **ops-shell image** (`backup_image`) published and reachable.

### Object storage (S3)
- [ ] **Buckets created out-of-band** — tofu manages only their **CORS** (`cors.tf`), not the
      buckets themselves. You need: **public** (must serve objects **public-read**), **private**,
      and (if `enable_backup`) a **backup** bucket.
- [ ] Credentials ready for `secrets.auto.tfvars` (see below).

### DNS
- [ ] `web_domain` for each env (and staging's `mailpit_domain`) resolves to the Coolify
      server, so Traefik can route it and issue TLS. Set these before apply or the health check
      / first deploy has nowhere to land.

### Reverse-proxy trust boundary
- [ ] Confirm the web container's port (`:8000`) is reachable **only** via Coolify's Traefik on
      the internal docker network — never exposed directly to clients. The stack sets
      `TRUSTED_PROXIES = "0.0.0.0/0"` (trust any upstream) so Symfony honors `X-Forwarded-Proto`
      / `-For` from the proxy. That is safe **only** under this assumption: if the container port
      is published directly, or fronted by a different proxy topology, a client could spoof those
      headers. If your topology differs, narrow `TRUSTED_PROXIES` (in `static_env`) to the actual
      proxy CIDR(s) before apply.

### Secrets & vars filled in
- [ ] `secrets.auto.tfvars` (git-ignored) — copy from `.example` and fill:
  - `coolify_endpoint`, `coolify_token`
  - per-env `server_uuid` (inside `secrets_production` / `secrets_staging`)
  - `app_secret`, `instance_id`, `rabbitmq_password` — `openssl rand -hex 16`, **stable across
    deploys**, distinct per env
  - `s3_access_key_id` / `s3_secret_access_key`
  - `mailer_dsn` — production SMTP (staging ignores it, uses Mailpit)
  - `mailpit_ui_auth` — staging Mailpit UI basic-auth (`user:password`); empty ⇒ open UI
  - `s3_backup_access_key_id` / `s3_backup_secret_access_key` — when `enable_backup = true`
- [ ] `*.tfvars` — set `project_name` (project-wide) and the per-env `production` / `staging`
      objects (`web_image*`, `web_domain`, `s3`, `app_env`, toggles, `backup`, …).
- [ ] **Back up `secrets.auto.tfvars` and `tofu.tfstate`** off-machine — with the default local
      backend they are the only copy. For a single operator that's all you need; if you'll share
      state across people/machines, see `STATE.md` for the remote (S3) + optional encryption path.

---

## [B] One-time manual steps after the first run (per environment)

The provider can't express these; do them once per env after the resources exist.

1. [ ] **`chown` the log dir** so the container (UID 82) can write — otherwise Shopware logging
       fails with *Permission denied*:
       ```bash
       mkdir -p <log_host_base>/<env>/var/log && chown -R 82:82 <log_host_base>/<env>/var/log
       ```
2. [ ] **Basic-auth `.htpasswd`** (envs with `enable_basic_auth = true`, typically staging) —
       HTTP basic-auth is a **Shopware-image** feature, not a tofu one: the `final-protected`
       build stage bakes an nginx snippet (`shopware/docker/nginx-basic-auth/basic-auth.inc`)
       whose `auth_basic_user_file` sets the container path **`/var/www/auth/.htpasswd`**. Tofu's
       only role is the bind mount of `<log_host_base>/<env>/auth` → the container's `/var/www/auth`.
       Create the file on the host so the hash never enters the repo/image:
       ```bash
       mkdir -p <log_host_base>/<env>/auth
       htpasswd -nbB <user> '<pw>' > <log_host_base>/<env>/auth/.htpasswd
       chown -R 82:82 <log_host_base>/<env>/auth
       ```
       (The env must also run the `final-protected` image target for the snippet to be present.)
3. [ ] **DB / Redis tuning in the Coolify UI** — `mariadb_conf` / `redis_conf` are set to `null`
       in `databases.tf` because Coolify 4.1.2 rejects the provider's extended-fields update.
       Set `my.cnf` / `redis.conf` in the Coolify UI if you need tuning.
4. [ ] **Build the Elasticsearch indices** (envs with `enable_elasticsearch = true`) — after the
       deploy that wires ES, in the web container:
       ```bash
       bin/console es:index          # storefront
       bin/console es:admin:index    # admin search
       ```
       then **redeploy the workers** so they pick up the ES env. Until built, search falls back
       to the DB (`SHOPWARE_ES_THROW_EXCEPTION=0`) — nothing 500s in the meantime.

> Not manual: `connect_to_docker_network` (rabbitmq / workers / elasticsearch / backup joining
> the shared network) is automated by `null_resource`s, since the provider can't round-trip the
> flag. No action needed.

---

## [C] The recurring rule: env changes need a redeploy

`tofu apply` only **writes** env vars into Coolify's config — Coolify injects them at
**(re)deploy** time. After changing any env value, **redeploy** the affected `web` app /
`workers` service (Coolify UI → Redeploy, or `POST /api/v1/deploy?uuid=…&force=true`).

The `coolify_envs_bulk` vars are write-only to the provider, so tofu re-pushes them every apply
and **can't detect drift** — always pair an env change with a manual redeploy. Skipping it is a
common cause of an env change appearing to have no effect.
