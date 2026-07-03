# Provider & Coolify Quirks

The non-obvious `coolify-terraform/coolify` provider and Coolify behaviours this stack works
around, and **why the `.tf` looks the way it does**. Read the relevant entry before "fixing"
something that looks odd. Provider version `0.1.7`.

## Provider basics
- Source `coolify-terraform/coolify`, version `0.1.7`. Auth + server reachability confirmed at
  `tofu plan` (30 resources, 0 errors).
- A child module needs its own `required_providers` (coolify) or `tofu init` infers
  `hashicorp/coolify` and fails (`modules/shopware-stack/versions.tf`).
- `coolify_service.type` must be a LITERAL: the config validator treats a `var.` reference as
  unset and fails `tofu validate` — the slugs are inlined.

## Reconcile / drift (the core IaC value)
- Deleted both RabbitMQ services manually in the Coolify UI; the next `tofu plan` refreshed,
  reported "has been deleted", and planned to recreate them — no error, no manual import. The
  provider's Read returns "gone" cleanly; this is the self-healing reconcile behaviour.

## State recovery — rebuilding `tofu.tfstate` from the server
- `tofu import` tested live (into a throwaway state; real state/Coolify untouched). Imports
  succeed for every resource type we use: `coolify_project`, `coolify_database_mariadb`,
  `coolify_application_docker_image`, `coolify_service` (all by bare UUID) and `coolify_envs_bulk`
  (id form `application:<uuid>`).
- Generated secrets ARE recoverable: importing the mariadb re-reads `internal_db_url` (carries
  the Coolify-generated password); Redis is the same. Our *owned* secrets
  (app_secret/instance_id/rabbitmq_password) live in `secrets.auto.tfvars`, not state — so a lost
  state file loses NO secret.
- `coolify_envs_bulk.variables` are write-only (the perpetual-diff quirk) and do NOT come back on
  import — but they don't need to: they're sourced from `locals.tf` and re-pushed next apply.
- Catch: recovery is MANUAL and per-resource — ~30 `tofu import` calls, each needing a
  hand-collected UUID. Tedious, not data-loss. A remote backend mainly saves that slog.

## Private registry auth (a real gap)
- `coolify_application_docker_image` does NOT pull a private image on its own — the web deploy
  FAILED pulling `ghcr.io/.../` (private, no auth).
- The provider models NO registry credentials (confirmed via schema): the only credential-ish
  resources are `coolify_private_key` (server SSH) and `coolify_github_app` / `coolify_cloud_token`
  (Coolify-platform auth). `coolify_application_docker_image` has no registry-auth attribute (its
  `http_basic_auth_*` fields protect the deployed app's HTTP, not the image pull).
- So registry auth is an out-of-band manual step: `docker login ghcr.io` on the Coolify host, or a
  GitHub PAT via Coolify's UI "Private Registry" — not expressible in this provider.

## Workers/scheduler: run as a compose service, not an image app (the hard one)
- The image ENTRYPOINT is `supervisord` (nginx+php-fpm) and **ignores CMD**, so a `start_command`
  alone ran the full WEB SERVER for every worker/scheduler. Worse: with `ports_exposes` required
  and `domains` auto-generated, those extra web servers got sslip.io domains and Traefik
  round-robined the storefront across them — a "phantom container" that survived stopping the web
  app and served a stale/empty DB.
- `custom_docker_run_options = "--entrypoint=php"` + bare `bin/console` CMD: `--entrypoint=php`
  works at the raw `docker run` level, but Coolify's translation of `custom_docker_run_options` +
  `start_command` into its generated compose is unreliable — the container booted broken and
  exited instantly (created → started → gone, no logs). Not viable.
- ✅ **What works: a `coolify_service` with `docker_compose_raw`** (workers.tf), where
  `entrypoint:` is first-class compose. One service, three compose services (worker-1/2 +
  scheduler), each `entrypoint: ["php","bin/console",…]`. Containers `Up`, `Command = php
  bin/console messenger:consume`, logs `[OK] Consuming messages…`. Consequences:
  - `docker_compose_raw` is constant → the image ref + full app env are injected via
    `coolify_envs_bulk` (`APP_IMAGE` + `local.shared_env`) and consumed with `$${APP_IMAGE}`
    interpolation + `env_file: .env` (Coolify writes the service's env to that file — this delivers
    `DATABASE_URL`/AMQP to the containers).
  - A service lands on its own compose network → needs the `connect_to_docker_network`
    null_resource (below) to reach the DBs + rabbitmq.
  - **var/log host bind mount — SHORT vs LONG compose syntax matters.** Coolify slugifies a
    short-form volume source (`${X}:/path` or a literal `/host:/path`) into a managed NAMED volume
    (empty host source), and `coolify_storage` doesn't attach to service containers. Fix: the LONG
    form so it stays a real bind (Coolify keeps the host source AND interpolates it):
    ```
    volumes:
      - type: bind
        source: $${LOG_HOST_PATH}   # injected via envs_bulk
        target: /var/www/html/var/log
    ```
    Confirmed `bind /data/shopware/<env>/var/log -> /var/www/html/var/log`, so worker logs share
    web's host var/log and show in the Shopware admin (FroshTools).
  - Graceful drain is native (`stop_signal: SIGTERM`, `stop_grace_period: 120s`).
  - `worker_count` parameterization is lost (compose constant → workers hardcoded to 2).
- **Operational trap:** repeated `force` redeploys + resource recreations leave orphaned containers
  Coolify no longer tracks, still holding Traefik labels. `tofu destroy` / Coolify "stop" won't
  remove them — only host `docker rm -f` does. Symptom: a domain keeps serving after its app is
  stopped. Check `docker ps` on the host early.

## No environment-level shared variables → per-app fan-out
- The ONLY env-var resources are `coolify_envs_bulk` and `coolify_environment_variable`, both
  targeting a single application/database/service UUID. `coolify_environment` and `coolify_project`
  have NO `variables` attribute — the provider does not expose Coolify's environment-level Shared
  Variables at all (a genuine provider gap).
- Consequence: we fan the full env map out to EVERY app individually (web + N workers + scheduler
  each get their own copy via `coolify_envs_bulk`). Coolify itself supports shared variables (the
  .env-web-blueprint relies on `{{ environment.X }}`); the provider just doesn't model them.
- Couples with the `coolify_envs_bulk` perpetual-diff: every plan re-pushes the full env to all
  apps, ×app count.

## Services as self-managed compose (rabbitmq / elasticsearch)
- Dropped the catalog `type` for RabbitMQ + ElasticSearch in favour of `docker_compose_raw`, to
  (a) suppress the auto-generated public URL and (b) own the RabbitMQ password (no UI capture).
- RabbitMQ comes up with our password via `${RABBITMQ_PASSWORD}` (service env). ✅
- Omitting `SERVICE_FQDN` yields NO public URL — the service stays internal-only. ✅
- `web`/`workers` reach RabbitMQ on the shared network at its container name `rabbitmq-<uuid>`
  (`local.amqp_base`) — only after the `connect_to_docker_network` null_resource runs (below); the
  bare `rabbitmq` host does NOT resolve. ✅
- ElasticSearch single-node (security off) is reachable at `elasticsearch-<uuid>:9200`
  (`local.es_url`) on the same shared network. ✅ (indices still need the one-time build.)

## Worker draining
- The host-level `docker-shutdown.sh` (docker ps/update/exec across containers) CANNOT run as a
  Coolify pre_deployment_command — that runs inside one app's image, no host docker socket. It's a
  monolithic-compose artifact.
- In the decomposed model the drain is per-container: Symfony Messenger exits cleanly on SIGTERM
  (finishes the in-flight message), so Coolify's stop-on-redeploy IS the graceful drain given
  enough grace before SIGKILL. Wired natively in the workers compose service (workers.tf):
  `stop_signal: SIGTERM` + `stop_grace_period: 120s` per worker/scheduler; prod redeploys workers
  on every deploy without stuck/lost messages. So the "imperative drain OpenTofu can't express"
  concern dissolves — it's declarative.
- (Optional belt-and-suspenders: `bin/console messenger:stop-workers` as a pre_deployment_command
  sets a Redis stop-flag — only an optimization; the image swap still happens via each worker's
  SIGTERM redeploy.)

## DB/Redis credentials (consumed, not set)
- Omitting `mariadb_password` / `mariadb_root_password` / `redis_password` lets Coolify
  autogenerate them (no "required argument" error) — plan shows them as computed `(sensitive
  value)`. ✅
- `coolify_database_mariadb.main.internal_db_url` is accepted by Shopware as `DATABASE_URL` as-is
  (user `shopware`, db `shopware`, internal host). ✅ (prod runs on it.)
- Each Redis `internal_db_url` works directly as `REDIS_CACHE_URL` / `REDIS_SESSION_URL`. ✅
- Redis is cache + session only; `LOCK_DSN` points at `DATABASE_URL` (Symfony DoctrineDbalStore
  auto-creates `lock_keys`), matching the .env-web-blueprint default — no dedicated lock Redis. ✅

## DB tuning (`mariadb_conf` / `redis_conf`) — must be set in the UI
- Encoding FLIPPED in 0.1.7: the DB code path does NO transform, sends the value verbatim, and the
  Coolify API rejects non-base64 with HTTP 422 ("should be base64 encoded") — so 0.1.7 wants
  `base64encode(...)`. (Verified against internal/service/database/{common.go,mariadb,redis} at
  v0.1.7.) The flip — schema docs vs behaviour changing across patch releases — is a maturity data
  point.
- Deeper blocker: after Create, 0.1.7 issues an UpdateDatabase whenever conf (or any extended
  field) is set, and its payload always includes `enable_ssl`, `is_log_drain_enabled`,
  `is_include_timestamps` — which this Coolify API rejects with HTTP 422 "This field is not
  allowed". The update can NEVER succeed here, leaving the DB tainted with a null `internal_db_url`.
  Since conf is the only thing that triggers the update (HasExtendedFields=false otherwise), the
  workaround is `mariadb_conf = redis_conf = null` (databases.tf) → no update → clean create.
  ⛔ The provider cannot manage DB tuning against this Coolify release at all — set `my.cnf` /
  `redis.conf` in the Coolify UI; the intended values live in the `mariadb_conf` / `redis_conf`
  tfvars.

## `connect_to_docker_network` — needs an out-of-band API call
- `coolify_service.connect_to_docker_network = true` → "Provider produced inconsistent result
  after apply" (sends true, reads back false). The service IS created and saved to state, but the
  apply errors, and the service lands on its own compose network (so `amqp://…@rabbitmq…` fails
  "hostname lookup failed"). Closed declaratively with a `null_resource` (services.tf / workers.tf /
  backup.tf) that local-execs a Coolify API PATCH `connect_to_docker_network=true` + restart right
  after the service is created, so it rejoins the shared predefined network. Keyed on the service
  UUID → a fresh `tofu apply` self-corrects, no UI toggle. Needs `curl` on the tofu host. (A
  provider gap: a core attribute needs an out-of-band API call to stick.)

## `coolify_envs_bulk` — perpetual diff (write-only)
- `variables` is write-only/sensitive and not read back, so every `tofu plan` shows all app
  env-sets as "update in-place" even when nothing changed. Idempotent, but env vars get re-pushed
  each apply and real drift in them isn't detected. Always pair an env change with a manual redeploy
  — Coolify only injects env at (re)deploy time.

## `coolify_scheduled_task` — works, service-attached only
- Confirmed against schema + a live apply. Attaches to a **service** via `service_uuid` (not an
  application); cron is a plain string in `frequency` (e.g. `"0 2 * * *"`) — no separate
  interval/timezone modeling.
- Used for backups (backup.tf): two tasks (`backup-db`, `backup-s3`) both point `service_uuid` at
  the same idle `backup` service and `command` a script's absolute path (`/var/www/html/bin/*.sh`),
  which Coolify `exec`s into the running container on the cron.
- The backup service reuses the compose-service pattern (constant `docker_compose_raw`, image+env
  via `coolify_envs_bulk` + `env_file: .env`, plus the `connect_to_docker_network` null_resource) —
  no new gap, the established workaround reapplied.
- **Single-service compose keeps the task target unambiguous:** `coolify_scheduled_task` has no
  container-selector — it execs into "the" container behind `service_uuid`. A multi-container
  compose would make that ambiguous, so the backup service is deliberately one compose service
  (idle on `tail -f /dev/null`). Design around this if a future service needs scheduled tasks
  alongside multiple containers.

## Env coverage vs `shopware/docker/.env-web-blueprint`
- The full blueprint env is set: `computed_env` (APP_SECRET, INSTANCE_ID, APP_URL, DATABASE_URL,
  LOCK_DSN, REDIS_CACHE_URL/SESSION_URL, the 3 MESSENGER DSNs, the ES block, the 7 `S3_*` vars,
  MAILER_DSN) + `static_env` (APP_ENV, APP_DEBUG, TRUSTED_PROXIES, SHOPWARE_HTTP_CACHE_*, monolog,
  …). The main AMQP queue is `/async` (blueprint-aligned; was `/messages`). `APP_IMAGE` is only
  needed by the compose-based worker/backup services (injected via their `envs_bulk`).

## Other gotchas
- Every `coolify_application_docker_image` defaults to `ports_exposes` + an HTTP health check
  (GET / on the exposed port). worker/scheduler/mailpit run no HTTP server there → would flap. Set
  `health_check_enabled = false` for them.
- Web `ports_exposes = "8000"` (the shopware/docker nginx serves on 8000); health check is
  Shopware's `/api/_info/health-check` (200) with a 30s `start_period` so a slow first boot isn't
  de-routed. `pre_deployment_command` / `post_deployment_command` exist on the app resource (an
  alternative home for the worker drain, though the compose `stop_signal`/grace already covers it).
- **Build-time config vs runtime env — a whole class of "my change didn't take effect":** anything
  in `config/packages/*.yaml` (S3 filesystem, trusted_proxies, monolog, …) is BAKED INTO THE IMAGE
  at build (`shopware-cli project ci`). Coolify/tofu env vars are RUNTIME and apply immediately, but
  a YAML change needs an image rebuild + redeploy. (We chased S3-media-going-local for ages before
  realizing the deployed image predated the S3 block.) Also: the build stage must be `-php-8.4` to
  match the lock/runtime — `-php-8.3` fails `composer install`. The Dockerfile is generated by
  shopware/docker — re-verify if regenerated.
- **How env actually reaches the app:** Coolify writes the resource's env vars to a `.env` file
  ("Creating .env file with runtime variables" in the deploy log). Services load it via
  `env_file: .env`; the web app's Symfony Dotenv reads it. The CLI/`exec`/post-deploy path also gets
  env — which is why `bin/console` can work while a different/stale container serving HTTP does not.
  Don't debug env against the exec shell; confirm which container serves the request first.
- **S3 bucket CORS in tofu:** managed with the `hashicorp/aws` provider pointed at the Hetzner
  endpoint (`endpoints.s3`, `s3_use_path_style`, `skip_*`). Gotcha: the AWS provider validates
  `region` against real AWS regions and rejects `hel1`; with an endpoint override the region is only
  a SigV4 signing placeholder, so use `us-east-1`. Needed because storefront fonts (.woff2) are
  fetched cross-origin from the S3 host and require `Access-Control-Allow-Origin`. See cors.tf.
- **Teardown:** `tofu destroy` may leave orphaned containers (they keep Traefik labels and can keep
  serving a domain); remove them on the host with `docker rm -f`.
