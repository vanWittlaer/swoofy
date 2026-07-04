# --- Coolify connection -------------------------------------------------------

variable "coolify_endpoint" {
  type        = string
  description = "Coolify API endpoint, e.g. https://coolify.example.com"
}

variable "coolify_token" {
  type        = string
  description = "Coolify API token (Security > API Tokens)"
  sensitive   = true
}

# --- Coolify project ----------------------------------------------------------
# One Coolify project holds both environments (production default + staging). Name and
# description are parameterized so the stack isn't tied to a specific project — set them
# per adopting project in <env>.tfvars (project-wide, non-secret; kept with backup_image).

variable "project_name" {
  type        = string
  description = "Coolify project name that owns the production + staging environments."
}

variable "project_description" {
  type        = string
  default     = "Shopware on Coolify (managed by OpenTofu)"
  description = "Coolify project description."
}

# --- Backup image (environment-agnostic; one tag serves prod + staging) -------
variable "backup_image" {
  type        = string
  default     = ""
  description = "Fully-qualified ref of the shell backup image (e.g. ghcr.io/<owner>/<repo>/shell). Required when either env sets enable_backup = true."
}

variable "backup_image_tag" {
  type        = string
  default     = "latest"
  description = "Tag for backup_image."
}

# The per-environment Coolify SERVER is not a top-level variable — it lives inside each
# secrets_production / secrets_staging object (server_uuid field), symmetric with the other
# per-env secrets, so both UUIDs stay in the git-ignored secrets.auto.tfvars. endpoint/token
# stay top-level: one control plane manages both servers (only server_uuid differs per env).

# --- Per-environment settings -------------------------------------------------
# production and staging share an identical shape; each environment's values live
# in its own <env>.tfvars file (production.tfvars / staging.tfvars).

variable "production" {
  type = object({
    web_image         = string # fully-qualified image ref incl. private registry host
    web_image_tag     = string # commit SHA or "latest"
    web_domain        = string # public storefront URL, e.g. https://shop.example.com
    app_env           = string # Symfony APP_ENV — "prod"
    app_debug         = optional(string, "0")
    monolog_log_level = optional(string, "error")
    # Optional infra toggles (default off), moved here from main.tf literals so each env
    # owns them: ES = storefront/admin search cluster; Mailpit = in-project SMTP sink.
    enable_elasticsearch = optional(bool, false)
    enable_mailpit       = optional(bool, false)
    enable_backup        = optional(bool, false)
    backup = optional(object({
      s3_backup_bucket      = string
      s3_backup_region      = string
      s3_backup_domain      = string
      s3_backup_path        = optional(string, "")
      db_backups_to_keep    = optional(number, 60)
      s3_backup_retain_days = optional(number, 30)
      db_schedule           = optional(string, "0 2 * * *")
      s3_schedule           = optional(string, "30 2 * * *")
    }), null)
    # Optional DB tuning (plain text; base64-encoded for the provider). Omit = image
    # defaults. mariadb_conf = my.cnf content; redis_conf keyed by role cache/session.
    mariadb_conf = optional(string, "")
    redis_conf   = optional(map(string), {})
    # S3 object storage (non-secret half; credentials are in secrets_production).
    s3 = object({
      bucket_private = string
      bucket_public  = string
      region         = string
      endpoint       = string
      cdn_domain     = optional(string, "")
      path_prefix    = optional(string, null) # null => "<env>/"; "" => bucket root
    })
  })
  description = "Production environment settings (see production.tfvars)"
}

variable "staging" {
  type = object({
    web_image         = string
    web_image_tag     = string
    web_domain        = string
    app_env           = string # Symfony APP_ENV — "stage"
    app_debug         = optional(string, "0")
    monolog_log_level = optional(string, "error")
    # Optional infra toggles (default off) — see production object above.
    enable_elasticsearch = optional(bool, false)
    enable_mailpit       = optional(bool, false)
    # FQDN for the Mailpit web UI when enable_mailpit=true (e.g. "https://mail.staging.example.com").
    # Coolify/Traefik routes it to Mailpit's 8025; access is gated by MP_UI_AUTH (secrets_staging).
    mailpit_domain = optional(string, "")
    enable_backup  = optional(bool, false)
    backup = optional(object({
      s3_backup_bucket      = string
      s3_backup_region      = string
      s3_backup_domain      = string
      s3_backup_path        = optional(string, "")
      db_backups_to_keep    = optional(number, 60)
      s3_backup_retain_days = optional(number, 30)
      db_schedule           = optional(string, "0 2 * * *")
      s3_schedule           = optional(string, "30 2 * * *")
    }), null)
    mariadb_conf = optional(string, "")
    redis_conf   = optional(map(string), {})
    s3 = object({
      bucket_private = string
      bucket_public  = string
      region         = string
      endpoint       = string
      cdn_domain     = optional(string, "")
      path_prefix    = optional(string, null) # null => "<env>/"; "" => bucket root
    })
  })
  description = "Staging environment settings (see staging.tfvars)"
}

# --- Shared non-secret env ----------------------------------------------------

variable "static_env" {
  type        = map(string)
  description = "Non-secret shared env applied to web/workers/scheduler (both environments). Per-env values (APP_ENV, APP_DEBUG) live in the production/staging objects instead."
  default = {
    # Coolify's proxy terminates TLS and forwards plain HTTP to the container, so Symfony
    # must trust X-Forwarded-Proto (wired in config/packages/framework.yaml) to generate
    # https URLs — otherwise admin/storefront assets are http → blocked as mixed content.
    #
    # Must be a literal IP/CIDR list here: the "private_ranges" magic token is only expanded
    # to real subnets by Symfony's framework-bundle config normalizer for a LITERAL yaml value.
    # Our config reads it via %env(TRUSTED_PROXIES)%, so the token would reach
    # Request::setTrustedProxies() unexpanded (as the string "private_ranges") and match no IP —
    # the proxy is never trusted and X-Forwarded-Proto is ignored. (The uppercase runtime tokens
    # REMOTE_ADDR / PRIVATE_SUBNETS *are* expanded by HttpFoundation, but we don't need them.)
    # 0.0.0.0/0 trusts any upstream — safe because the container's :8000 is only reachable via
    # Traefik on Coolify's internal docker network, never directly.
    TRUSTED_PROXIES = "0.0.0.0/0"
  }
}

# --- Log persistence ----------------------------------------------------------
# Base host directory for the var/log bind mount. Each environment gets its own
# <base>/<env>/var/log subtree so the paths never collide when prod and staging point at
# the same server. Harmless when they're on separate servers. Set "" to disable the bind
# mount and keep logs ephemeral in-container.
variable "log_host_base" {
  type        = string
  description = "Base host directory for per-environment Shopware var/log bind mounts (<base>/<env>/var/log). Empty disables the bind mount."
  default     = "/data/shopware"
}

# --- Secrets (provided via git-ignored secrets.auto.tfvars) --------------------

# Values Coolify can't produce for us — generate once, keep stable, set per
# environment (prod != staging).
#   - server_uuid      : the Coolify server this env deploys onto (an existing server's id,
#                        NOT a generated secret; same UUID both = co-located, different = split).
#   - app_secret       : Symfony/Shopware framework secret (CSRF, signed URIs, cookies).
#   - instance_id      : Shopware instance identifier (normally written to .env by
#                        `system:setup`; we don't run that at deploy, so we supply it).
#   - rabbitmq_password: we run RabbitMQ from our own compose with a known password
#                        (services.tf), so the AMQP DSN is derived, not captured.
#   - s3_access_key_id / s3_secret_access_key: object-storage credentials for the
#                        private/public filesystems (issued by your S3 provider).
# Generate the first three with `openssl rand -hex 16`; the S3 pair comes from your
# object-storage provider. DB/Redis creds still come from Coolify.
variable "secrets_production" {
  type = object({
    # Coolify server this environment deploys onto. Not a credential, but per-env and kept
    # here (with the other git-ignored per-env values) so prod and staging are symmetric —
    # same UUID as staging to co-locate, a different UUID to split across servers.
    server_uuid                 = string
    app_secret                  = string
    instance_id                 = string
    rabbitmq_password           = string
    s3_access_key_id            = string
    s3_secret_access_key        = string
    s3_backup_access_key_id     = optional(string, "")
    s3_backup_secret_access_key = optional(string, "")
    # Real SMTP DSN for production outbound mail. Defaults to Symfony's null transport
    # (mail discarded) until you set a real one, so a missing value doesn't break apply.
    mailer_dsn = optional(string, "null://null")
  })
  sensitive = true
}

variable "secrets_staging" {
  type = object({
    server_uuid                 = string # Coolify server for staging (see secrets_production)
    app_secret                  = string
    instance_id                 = string
    rabbitmq_password           = string
    s3_access_key_id            = string
    s3_secret_access_key        = string
    s3_backup_access_key_id     = optional(string, "")
    s3_backup_secret_access_key = optional(string, "")
    # Mailpit web-UI basic auth (MP_UI_AUTH), used when enable_mailpit=true. One or more
    # space-separated "user:password" pairs. Empty => Mailpit UI is unauthenticated.
    mailpit_ui_auth = optional(string, "")
  })
  sensitive = true
}
