# Spike Findings

Fill this in as you run the applies. It feeds the go/no-go decision for `coolshop-cli`.

## Provider
- Resolved provider source string at `tofu init`: `coolify-terraform/coolify` ✅
- Resolved version: `0.1.7` ✅
- Auth + server reachability confirmed at `tofu plan` (30 resources, 0 errors). ✅

## Reconcile / drift (the core IaC value)
- Deleted both RabbitMQ services manually in the Coolify UI; next `tofu plan`
  refreshed, reported "has been deleted", and planned to recreate them — no error,
  no manual import. ✅ The provider's Read returns "gone" cleanly. This is the
  self-healing behaviour the spike set out to validate.

## State recovery — can tofu.tfstate be rebuilt from the server?
- Tested `tofu import` live (into a throwaway state; real state/Coolify untouched).
  Imports succeed for every resource type we use: `coolify_project`,
  `coolify_database_mariadb`, `coolify_application_docker_image`, `coolify_service`
  (all by bare UUID) and `coolify_envs_bulk` (id form `application:<uuid>`). ✅
- Generated secrets ARE recoverable: importing the mariadb re-reads `internal_db_url`
  (carries the Coolify-generated password). Redis is the same pattern. Our *owned*
  secrets (app_secret/instance_id/rabbitmq_password) live in secrets.auto.tfvars, not
  state — so a lost state file loses NO secret.
- `coolify_envs_bulk.variables` are write-only (the perpetual-diff quirk) and do NOT
  come back on import — but they don't need to: they're sourced from locals.tf and
  re-pushed on the next apply.
- Catch: recovery is MANUAL and per-resource — no bulk import, ~30 `tofu import`
  calls, each needing a hand-collected UUID. Tedious, not data-loss.
- Go/no-go: (a) local-backend risk is lower than it looks — state loss is recoverable;
  a remote backend mainly saves the 30-import slog. (b) Another point FOR coolshop-cli:
  it could automate adoption/recovery by querying the Coolify API for UUIDs and running
  the imports — one command instead of 30.
## Risk R — private registry auth
- Did `coolify_application_docker_image` pull the private image directly? **No** — web
  deployment FAILED pulling `ghcr.io/vanwittlaer/swoofy/*` (private image, no auth).
- The provider models NO registry credentials: confirmed via schema, the only
  credential-ish resources are `coolify_private_key` (server SSH) and
  `coolify_github_app` / `coolify_cloud_token` (Coolify-platform auth). The
  `coolify_application_docker_image` resource has no registry-auth attribute (its
  `http_basic_auth_*` fields protect the deployed app's HTTP, not the image pull).
- So registry auth is an **out-of-band manual step**: `docker login ghcr.io` on the
  Coolify host, or store a GitHub PAT via Coolify's UI "Private Registry" feature. Not
  expressible in this provider. ✅ confirmed gap.
- Go/no-go: a clean point FOR coolshop-cli — the CLI could drive the Coolify API
  registry endpoints (or the host login) that the OpenTofu provider omits, closing a
  bootstrap gap that otherwise needs a documented manual step.

## Risk W — worker/scheduler entrypoint + replicas ⛔→✅ RESOLVED (the hard one)
- The image ENTRYPOINT is `supervisord` (nginx+php-fpm) and **ignores CMD**, so **Attempt A**
  (`start_command` alone) ran the full WEB SERVER for every worker/scheduler. Worse: with
  `ports_exposes` required and `domains` auto-generated, those extra web servers got
  sslip.io domains and **Traefik round-robined the storefront domain across them** — a
  "phantom container" that survived stopping the web app and served a stale/empty DB.
- **Attempt B** (`custom_docker_run_options = "--entrypoint=php"` + bare `bin/console` CMD):
  `--entrypoint=php` works fine at the raw `docker run` level (verified), but Coolify's
  translation of `custom_docker_run_options` + `start_command` into its generated compose is
  unreliable — the container booted broken and **exited instantly** (created → started →
  gone, no logs). Not viable.
- ✅ **What worked = run them as a `coolify_service` with `docker_compose_raw`** (workers.tf),
  where `entrypoint:` is first-class compose. One service, three compose services
  (worker-1/2 + scheduler), each `entrypoint: ["php","bin/console",…]`. Confirmed: containers
  `Up`, `Command = php bin/console messenger:consume`, logs show `[OK] Consuming messages…`.
  Consequences of the switch:
  - `docker_compose_raw` is constant → the image ref + full app env are injected via
    `coolify_envs_bulk` (`APP_IMAGE` + `local.shared_env`) and consumed with `$${APP_IMAGE}`
    interpolation + `env_file: .env` (Coolify writes the service's env vars to that file —
    this DID deliver `DATABASE_URL`/AMQP to the containers).
  - A service lands on its own compose network → needs the same `connect_to_docker_network`
    null_resource as rabbitmq to reach the DBs + rabbitmq.
  - **var/log host bind mount — SHORT vs LONG compose syntax matters.** Coolify slugifies a
    short-form volume source (`${X}:/path` or even a literal `/host:/path`) into a managed
    NAMED volume (empty host source), and `coolify_storage` doesn't attach to service
    containers at all. The fix (matches the original shopware/docker/worker compose): use the
    **long form** so it stays a real bind — Coolify keeps the host source AND interpolates it:
    ```
    volumes:
      - type: bind
        source: $${LOG_HOST_PATH}   # injected via envs_bulk (our SERVER_VOLUME equivalent)
        target: /var/www/html/var/log
    ```
    Confirmed `bind /data/shopware/<env>/var/log -> /var/www/html/var/log`. This lets the
    workers share web's host var/log so worker logs show in the Shopware admin (FroshTools).
  - Graceful drain is expressed natively (`stop_signal: SIGTERM`, `stop_grace_period: 120s`).
  - `worker_count` parameterization is lost (compose is constant → workers hardcoded to 2).
- **Operational trap this exposed:** repeated `force` redeploys + resource recreations leave
  **orphaned containers Coolify no longer tracks**, still holding Traefik labels. `tofu
  destroy` / Coolify "stop" won't remove them — only host `docker rm -f` does. Symptom: a
  domain keeps serving after its app is stopped. Check `docker ps` on the host early.

## Risk V — shared variables
- Confirmed against the provider schema: the ONLY env-var resources are
  `coolify_envs_bulk` and `coolify_environment_variable`, and both target a single
  `application` / `database` / `service` UUID. `coolify_environment` and
  `coolify_project` have NO `variables` attribute. So the provider does **not** expose
  Coolify's environment-level **Shared Variables** at all. ✅ (confirmed, not just expected)
- Consequence: we fan the full env map out to EVERY app individually (web + N workers +
  scheduler each get their own copy via `coolify_envs_bulk`). The blueprint's model —
  set once per environment as Coolify Shared Variables, reference via
  `{{ environment.X }}` — is NOT reproducible through this provider. Coolify itself
  supports it (the .env-web-blueprint relies on it); the OpenTofu provider just doesn't
  model it. A genuine provider-maturity gap and a point FOR coolshop-cli (the CLI could
  call the Coolify API's shared-variable endpoints the provider omits).
- Couples with the `coolify_envs_bulk` perpetual-diff quirk: every plan re-pushes the
  full env to all apps, multiplied by app count.

## Risk S — services (now self-managed compose, not catalog)
- Decision: dropped the catalog `type` for RabbitMQ + ElasticSearch in favour of
  `docker_compose_raw`, to (a) suppress the auto-generated public URL and (b) own the
  RabbitMQ password (no UI capture). Chicken-and-egg `rabbitmq_conn_*` removed.
- RabbitMQ comes up with our password via `${RABBITMQ_PASSWORD}` (service env var)? _____
- Did omitting `SERVICE_FQDN` actually yield NO public URL? _____
- Do `web`/`worker` reach RabbitMQ at host `rabbitmq` (internal DNS)? _____ (if not, this
  is the connect_to_docker_network gap — toggle predefined network in UI)
- ElasticSearch single-node (security off) reachable at host `elasticsearch:9200`? _____
- Ordering: did the service deploy before its env var propagated (needing a re-apply)? _____

## Risk D — graceful redeploy / worker draining
- Reframed: the host-level `docker-shutdown.sh` (docker ps/update/exec across
  containers) CANNOT run as a Coolify pre_deployment_command — that runs inside one
  app's image, no host docker socket. It's a monolithic-compose artifact.
- In the decomposed model the drain is per-container: Symfony Messenger exits cleanly
  on SIGTERM (finishes the in-flight message), so Coolify's stop-on-redeploy IS the
  graceful drain — given enough grace before SIGKILL. ✅ Wired natively in the workers
  compose service (workers.tf): `stop_signal: SIGTERM` + `stop_grace_period: 120s` on each
  worker/scheduler. (The earlier `custom_docker_run_options --stop-signal/--stop-timeout`
  on a coolify_application_docker_image is gone — workers are a docker_compose_raw service.)
- To verify at apply: redeploy a worker, confirm logs show Messenger catching the
  signal and exiting after the current message (not an abrupt kill). _____
- Verdict for go/no-go: Risk D — once a top argument for coolshop-cli ("imperative
  drain OpenTofu can't express") — largely DISSOLVES. Drain is now per-app SIGTERM +
  --stop-timeout, native to Coolify/docker and configured declaratively. _____
- (Optional belt-and-suspenders: `bin/console messenger:stop-workers` as a
  pre_deployment_command sets a Redis stop-flag — but only an optimization; the image
  swap still happens via each worker's SIGTERM redeploy.)

## DB/Redis credentials (consumed, not set)
- Omitting `mariadb_password` / `mariadb_root_password` / `redis_password` let Coolify
  autogenerate them (no "required argument" error at validate/apply)? ✅ plan shows them
  as computed `(sensitive value)`; provider generates them.
- `coolify_database_mariadb.main.internal_db_url` accepted by Shopware as `DATABASE_URL`
  as-is (right user `shopware`, db `shopware`, internal host)? _____
- Each Redis `internal_db_url` usable directly as REDIS_*_URL (db index ok)? _____
- Redis instances reduced to cache + session only. `LOCK_DSN` now points at
  `DATABASE_URL` (Symfony DoctrineDbalStore, auto-creates `lock_keys`), matching the
  .env-web-blueprint default — no dedicated lock Redis. _____

## Env coverage vs shopware/docker/.env-web-blueprint
- We currently set: APP_ENV, APP_DEBUG (static_env); APP_SECRET, INSTANCE_ID, APP_URL,
  DATABASE_URL, LOCK_DSN, REDIS_CACHE_URL, REDIS_SESSION_URL, and the 3 MESSENGER DSNs
  (computed_env). All present. ✅
- Aligned the main AMQP queue name to the blueprint: `MESSENGER_TRANSPORT_DSN` now ends
  in `/async` (was `/messages`). ✅
- NOT YET set, present in the blueprint (decide which the deploy actually needs):
  MAILER_DSN (staging has Mailpit but nothing points at it), TRUSTED_PROXIES,
  SHOPWARE_HTTP_CACHE_ENABLED / SHOPWARE_HTTP_DEFAULT_TTL, MONOLOG_LOG_LEVEL, LOG_CHANNEL,
  the S3_* block (7 vars), SERVER_VOLUME, SQL_SET_DEFAULT_SESSION_VARIABLES,
  APP_URL_CHECK_DISABLED, BLUE_GREEN_DEPLOYMENT. APP_IMAGE is only needed by the
  compose-based worker model — moot here since workers run as their own image apps.

## Provider quirks observed
- Child module needs its own `required_providers` (coolify) or `tofu init` infers
  `hashicorp/coolify` and fails. ✅ fixed (modules/shopware-stack/versions.tf).
- `coolify_service.type` must be a LITERAL: the config validator treats a `var.`
  reference as unset and fails `tofu validate`. ✅ inlined the slugs.
- `mariadb_conf` / `redis_conf` encoding **FLIPPED in provider 0.1.7**. The earlier note
  here said pass RAW (the provider encoded internally and read back decoded, so base64
  caused "inconsistent result after apply"). In 0.1.7 the DB code path does NO transform:
  it sends the value verbatim and the Coolify API rejects non-base64 with HTTP 422
  ("The mariadb_conf should be base64 encoded"), reading it back verbatim. So 0.1.7 wants
  `base64encode(...)` and round-trips cleanly. ✅ Fixed in databases.tf (verified against
  internal/service/database/{common.go,mariadb/resource.go,redis/resource.go} at v0.1.7).
  Knock-on: the 422 aborted the *update* mid-flight, leaving computed `internal_db_url`
  and `limits_cpuset` unknown → "Provider returned invalid result object after apply" on
  redis-cache and tainted all three DBs. Encoding the conf resolves both symptoms. The
  flip itself is a maturity data point — schema docs vs behavior, and behavior changing
  across patch releases.
- DB **extended-fields update is incompatible with this Coolify version** — the deeper
  blocker. After Create, 0.1.7 issues an UpdateDatabase whenever conf or any extended
  field is set, and its payload (SetUpdateExtended) always includes `enable_ssl`,
  `is_log_drain_enabled`, `is_include_timestamps`. This Coolify API rejects all three
  with HTTP 422 "This field is not allowed", so the update can NEVER succeed here → conf
  can't be applied and the DB is left tainted with a null internal_db_url. Since conf is
  the only thing we set that triggers the update (HasExtendedFields=false otherwise),
  the workaround is `mariadb_conf = redis_conf = null` in databases.tf → no update →
  clean create. DB tuning must be done in the Coolify UI until the provider stops
  sending those fields or Coolify accepts them. ⛔ Real go/no-go data point: the provider
  cannot manage DB tuning against this Coolify release at all.
- `coolify_service.connect_to_docker_network = true` → "Provider produced inconsistent
  result after apply" (sends true, reads back false). The service IS still created in
  Coolify and saved to state, but the apply errors. Left the attribute omitted (service
  lands on its own compose network, so the apps' `amqp://…@rabbitmq:5672` DSN fails with
  "hostname lookup failed"). ✅ Closed declaratively: `null_resource.rabbitmq_connect_network`
  (services.tf) runs a local-exec right after the service is created that PATCHes
  `connect_to_docker_network=true` via the Coolify API and restarts the service, so the
  container rejoins the shared predefined network and `rabbitmq` resolves from the apps.
  Keyed on the service UUID → a fresh `tofu apply` self-corrects, no UI toggle. Needs
  `curl` on the tofu host. (Still a provider-maturity data point for the go/no-go: a core
  attribute needs an out-of-band API call to stick.)
- `coolify_envs_bulk` has a PERPETUAL DIFF: `variables` is write-only/sensitive and not
  read back, so every `tofu plan` shows all 8 app env-sets as "update in-place" even when
  nothing changed. Idempotent, but means env vars get re-pushed each apply and real drift
  in them isn't detected. TODO verify: does re-pushing trigger an app redeploy each time?
  (Counts against "declarative reconcile covers everything" — a point worth weighing.)

## Other surprises
- Every `coolify_application_docker_image` defaults to `ports_exposes` + an HTTP
  health check (GET / on the exposed port). worker/scheduler/mailpit run no HTTP
  server on that port → would flap. Set `health_check_enabled = false` for them. ✅
- `pre_deployment_command` / `post_deployment_command` exist on the app resource —
  may let the graceful worker drain (Risk D) be expressed declaratively after all.
  Investigate before the go/no-go.
- Web `ports_exposes = "8000"` confirmed: the shopware/docker nginx serves on 8000. ✅
  Web health check set to Shopware's `/api/_info/health-check` (returns 200) on 8000, with
  a 30s `start_period` so a slow first boot/deploy doesn't get the container de-routed.
- **Build-time config vs runtime env — a whole class of "my change didn't take effect":**
  anything in `config/packages/*.yaml` (S3 filesystem, trusted_proxies, monolog, …) is
  BAKED INTO THE IMAGE at build time (`shopware-cli project ci`). Coolify/tofu env vars are
  RUNTIME and apply immediately, but a YAML change needs an **image rebuild + redeploy** to
  land. We chased S3-media-going-local for ages before realizing the deployed image
  predated the S3 block. Also: the build stage used `shopware-cli:latest-php-8.3` while the
  lock/runtime are 8.4 → `composer install` failed; bump the build image to `-php-8.4`
  (Dockerfile is generated by shopware/docker — re-verify if regenerated).
- **How env actually reaches the app:** Coolify writes the resource's env vars to a `.env`
  file for the container ("Creating .env file with runtime variables" in the deploy log).
  For services, `env_file: .env` in the compose loads them; for the web app Symfony Dotenv
  reads the file. The CLI/`exec`/post-deploy path also gets env, which is why `bin/console`
  can work while a *different/stale* container serving HTTP does not — don't debug env
  against the exec shell; confirm which container actually serves the request first.
- **S3 bucket CORS in tofu:** managed with the `hashicorp/aws` provider pointed at the
  Hetzner endpoint (`endpoints.s3`, `s3_use_path_style`, `skip_*` flags). Gotcha: the AWS
  provider validates `region` against real AWS regions and rejects `hel1`; with an endpoint
  override the region is only a SigV4 signing placeholder, so use `us-east-1` (Hetzner
  accepts it). Needed because storefront fonts (.woff2) are fetched cross-origin from the
  S3 host and require `Access-Control-Allow-Origin`. See cors.tf.

## `coolify_scheduled_task` — works, service-attached only
- Confirmed against the provider schema and a live apply: `coolify_scheduled_task` exists
  and works. It attaches to a **service** via `service_uuid` (not an application), and cron
  is set via `frequency` (a plain cron string, e.g. `"0 2 * * *"`) — no separate
  interval/timezone modeling to worry about.
- Used for the backup service (`backup.tf`): two `coolify_scheduled_task` resources
  (`backup-db`, `backup-s3`) both point `service_uuid` at the same idle `backup`
  `coolify_service` and `command` a script's absolute path (`/var/www/html/bin/*.sh`), which
  Coolify `exec`s into the running container on the cron in `frequency`.
- The backup service itself reuses the **Risk-W family pattern** (workers.tf): a
  `docker_compose_raw` service (constant string, image + env injected via
  `coolify_envs_bulk` + `$${APP_IMAGE}` / `env_file: .env`) plus the same
  `connect_to_docker_network` `null_resource` local-exec (services.tf/workers.tf) so the
  container reaches the DB/S3 on the shared network — no new provider gap here, just the
  established workaround reapplied.
- **Single-service compose keeps the scheduled task's target unambiguous.** The provider's
  `coolify_scheduled_task` has no container-selector field — it just execs into "the"
  container behind `service_uuid`. A multi-container compose (like the worker/scheduler
  service) would make that ambiguous; the backup service is deliberately kept to **one**
  compose service (idle on `tail -f /dev/null`) so there's exactly one container to exec
  into. If a future service needs scheduled tasks alongside multiple containers, this is the
  constraint to design around.
