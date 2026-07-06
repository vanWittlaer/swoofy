# Compatibility matrix

The versions this stack is **known to work with**, and the couplings that matter when you
bump any of them. This is what turns "works for us" into "safe to adopt" — read it before
upgrading OpenTofu, the Coolify provider, Coolify itself, or the Shopware base image.

Legend: **Pinned** = enforced in code (constraint or tag); **Floating** = resolved at
build/apply time (`latest`/loose range) and therefore a reproducibility risk to tighten
before a release.

## Tooling (Infrastructure-as-Code)

| Component | Version | Where pinned | Notes |
|-----------|---------|--------------|-------|
| OpenTofu (`tofu`) | **≥ 1.7.0** | `versions.tf` (`required_version`) | 1.7 is the floor for the provider + import support used here. |
| Provider `coolify-terraform/coolify` | **~> 0.1.7** (tested at 0.1.7) | `versions.tf` | Source is `coolify-terraform/coolify` — **not** `hashicorp/coolify` (which does not exist and fails at `init`). Carries the known limitations below. |
| Provider `hashicorp/aws` | **~> 5.0** | `versions.tf` | Used **only** for S3 bucket CORS (`cors.tf`) against the S3-compatible endpoint. Not for any AWS compute. |

## Control plane & host

| Component | Version | Where pinned | Notes |
|-----------|---------|--------------|-------|
| Coolify | **4.1.2** (validated against) | External (not managed here) | The provider-vs-Coolify quirks below were observed on 4.1.2. Newer Coolify may fix or shift them — re-validate on upgrade. |
| Coolify helper image | 1.0.14 | Coolify-managed | Seen at deploy time; informational. |
| Docker Engine (host) | 29.x + BuildKit/Buildx | External | Buildx required for the multi-stage image build. |

## Shopware application & production image

| Component | Version | Where pinned | Notes |
|-----------|---------|--------------|-------|
| `shopware/core` | **v6.7.11.1** | `shopware/composer.lock` | `composer.lock` is the source of truth; match any imported DB dump to it. |
| PHP | **8.4** | Base image tag (below) | Build + runtime are PHP 8.4; the base image dictates this. |
| Symfony | **7.4.x** | via `shopware/core` | Relevant to the `TRUSTED_PROXIES` behavior (env-injected value is not token-expanded — see `variables.tf`). |
| Base image `ghcr.io/shopware/docker-base` | **8.4-nginx** | `shopware/docker/Dockerfile` | nginx serves on **:8000** (health check + `ports_exposes` depend on this). |
| Build image `ghcr.io/shopware/shopware-cli` | `latest-php-8.4` — **Floating** | `shopware/docker/Dockerfile` | Pin to a released tag for reproducible builds. |
| `shopware/docker` (Composer) | **^0.3.0** | `shopware/composer.json` | Generates the Dockerfile — do not hand-edit the Dockerfile. |
| `shopware/deployment-helper` (Composer) | **^0.0.27** | `shopware/composer.json` | Runs the post-deploy `run` command (install/migrate/plugin/theme). |

## Backing services (provisioned by `modules/shopware-stack`)

| Service | Image / tag | Where pinned | Notes |
|---------|-------------|--------------|-------|
| MariaDB | `mariadb:11` | `databases.tf` | `mariadb_conf` tuning disabled via provider (Coolify 4.1.2 rejects the extended-fields update — set in UI). |
| Redis (cache + session) | `redis:7` | `databases.tf` | Two instances; `redis_conf` disabled for the same reason. Symfony lock uses the DB (`LOCK_DSN`), no lock Redis. |
| Elasticsearch | `elasticsearch:8.15.0` | `services.tf` | Must match Shopware's supported ES/OpenSearch range for the pinned core. Runs with `-Xmx512m`; real footprint ≫ heap (mind host RAM). |
| RabbitMQ | `rabbitmq:3.13-management` | `services.tf` | Management UI port is per-env (`rabbitmq_mgmt_port`). |
| Mailpit (staging only) | `axllent/mailpit:v1.30.3` | `services.tf` | Staging SMTP sink; reached via the stable per-env `mailpit-<env>` network alias. |

## Version-coupled constraints (why these versions matter)

These are the places where a version bump can break the stack — check them on any upgrade:

1. **Provider 0.1.7 forbidden-fields 422** — `mariadb_conf`/`redis_conf` extended-field updates
   are rejected by Coolify 4.1.2, so DB/Redis tuning is set to `null` in code and done in the
   Coolify UI. A newer provider/Coolify pair may lift this. (`databases.tf`)
2. **No `entrypoint` for image apps** — workers/scheduler use `start_command`; otherwise they
   boot the web server instead of their console command. (`apps.tf`, `workers.tf`)
3. **`connect_to_docker_network` can't round-trip** — the provider sends `true`, reads back
   `false`, so services (rabbitmq, elasticsearch, workers, backup) join the shared network via
   an out-of-band `null_resource` API PATCH. Applications appear to join by default. (`services.tf`)
4. **No shared/project-scoped variable resource** — shared env is fanned out per app via
   `coolify_envs_bulk` rather than a single project-scoped variable. (`env.tf`)
5. **`TRUSTED_PROXIES` must be a literal CIDR** — the `private_ranges` magic token is only
   expanded for a literal YAML value, not an env-injected one (Symfony 7.4). (`variables.tf`)
6. **PHP 8.4 hard floor** — set by the base image; an infra-only change that alters PHP needs
   an image rebuild, not just a `tofu apply`.

## Floating versions — pin, or keep floating on purpose

Not every `latest` is debt. Two of these float **by design** because CI/CD drives them; the rest
are reproducibility gaps to close for an adoptable release.

**Float by design (leave as-is on a live CD-driven stack):**

- `web_image_tag` / `backup_image_tag` = `latest` (in `*.tfvars`) — CI pushes `:latest` and the
  Coolify deploy webhook redeploys it. Pinning to a digest/SHA would mean hand-editing `*.tfvars`
  on every deploy, defeating the pipeline. Pin these **only** for an immutable/audited release
  where each deploy is a deliberate tag bump.

**Close before an adoptable release:**

- `shopware-cli` build image → `latest-php-8.4` (in `shopware/docker/Dockerfile`). Note the
  Dockerfile is **generated by the `shopware/docker` Composer package** — do not hand-edit it;
  pin via that package's config so a regenerate keeps the pin.
- Provider `~> 0.1.7` and `aws ~> 5.0` are ranges — fine for now, but pin exactly if you need
  bit-for-bit reproducibility across adopters.

`axllent/mailpit` is now pinned to `v1.30.3` (`services.tf`).

## On upgrade — recommended checklist

1. Bump one axis at a time (provider **or** Coolify **or** Shopware core), never several.
2. `tofu init -upgrade && tofu fmt -recursive && tofu validate && tofu plan` — inspect drift.
3. Re-verify the six version-coupled constraints above against the new versions.
4. For Shopware core / base-image bumps: rebuild the image and run the deployment-helper;
   confirm the ES version still matches the core's supported range.

## Deeper background (optional)

This doc is self-contained — every constraint above points at the module code that carries it.
For the full discovery notes behind the provider quirks (the "why", with reproduction detail),
see `FINDINGS.md`. It is project-internal context, not a dependency of this matrix.
