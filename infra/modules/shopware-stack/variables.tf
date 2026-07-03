variable "environment_name" {
  type        = string
  description = "Coolify environment name (production / staging)"
}

variable "project_uuid" {
  type = string
}

variable "server_uuid" {
  type = string
}

variable "web_image" {
  type = string
}

variable "web_image_tag" {
  type = string
}

variable "web_domain" {
  type = string
}

variable "enable_elasticsearch" {
  type    = bool
  default = false
}

variable "enable_mailpit" {
  type    = bool
  default = false
}

variable "mailpit_domain" {
  type        = string
  default     = ""
  description = "FQDN for the Mailpit web UI (enable_mailpit only), e.g. \"https://mail.staging.example.com\". Mapped to Mailpit's 8025 via Coolify/Traefik. Access is gated by MP_UI_AUTH (var.secrets.mailpit_ui_auth). Empty => no domain (UI reachable only internally)."
}

variable "enable_backup" {
  type        = bool
  default     = false
  description = "Deploy the backup service (idle shell container) + its scheduled tasks."
}

variable "backup_image" {
  type        = string
  default     = ""
  description = "Fully-qualified ref of the env-agnostic shell backup image (e.g. ghcr.io/<owner>/<repo>/shell). Required when enable_backup = true."
}

variable "backup_image_tag" {
  type        = string
  default     = "latest"
  description = "Tag for backup_image (commit SHA or \"latest\")."
}

variable "backup" {
  type = object({
    s3_backup_bucket      = string
    s3_backup_region      = string                         # e.g. "fsn1" — DIFFERENT location from the source buckets
    s3_backup_domain      = string                         # e.g. "https://fsn1.your-objectstorage.com"
    s3_backup_path        = optional(string, "")           # in-bucket prefix; keep prod/staging distinct if sharing a bucket
    db_backups_to_keep    = optional(number, 60)           # DB_BACKUPS_TO_KEEP
    s3_backup_retain_days = optional(number, 30)           # S3_BACKUP_RETAIN_DAYS (soft-delete retention)
    db_schedule           = optional(string, "0 2 * * *")  # cron for backup-db.sh
    s3_schedule           = optional(string, "30 2 * * *") # cron for backup-s3.sh
  })
  default     = null
  description = "Backup destination + schedules. Ignored when enable_backup = false. Credentials are in var.secrets (s3_backup_access_key_id / s3_backup_secret_access_key)."
}

variable "mariadb_conf" {
  type        = string
  description = "Custom my.cnf content (plain text). Empty = MariaDB image defaults."
  default     = ""
}

variable "redis_conf" {
  type        = map(string)
  description = "Custom redis.conf content per role (cache/session), plain text. Missing key = Redis image defaults. NB: cache may evict (allkeys-lru); session must NOT (noeviction). Lock uses the DB, not Redis."
  default     = {}
}

variable "static_env" {
  type        = map(string)
  description = "Non-secret shared env applied to web/workers/scheduler"
  default     = {}
}

variable "app_env" {
  type        = string
  description = "Symfony APP_ENV for this environment (\"prod\" for production, \"stage\" for staging)."
}

variable "app_debug" {
  type        = string
  default     = "0"
  description = "Symfony APP_DEBUG (\"0\"/\"1\"), set per environment."
}

variable "monolog_log_level" {
  type        = string
  default     = "error"
  description = "Monolog action level (env MONOLOG_LOG_LEVEL, see config/packages/prod/monolog.yaml), set per environment."
}

variable "mailer_dsn" {
  type        = string
  sensitive   = true
  default     = "null://null"
  description = "Symfony MAILER_DSN for outbound mail. Used only when enable_mailpit is false (production); staging overrides it with the in-project Mailpit. Provide a real SMTP DSN as a secret for production."
}

variable "coolify_endpoint" {
  type        = string
  description = "Coolify API endpoint — used by the local-exec that sets the rabbitmq connect_to_docker_network flag (provider can't round-trip it)."
}

variable "coolify_token" {
  type        = string
  sensitive   = true
  description = "Coolify API token — used by the rabbitmq connect_to_docker_network local-exec."
}

variable "mariadb_public_port" {
  type        = number
  default     = null
  description = "Host port to expose MariaDB on (maps to the container's 3306). null = internal-only. Goes through the provider Update path (diff-gated), so it does NOT trip the forbidden-field 422 that blocks mariadb_conf."
}

variable "rabbitmq_mgmt_port" {
  type        = number
  default     = 15672
  description = "Host port to expose the RabbitMQ management UI on (maps to the container's 15672). Injected into the service compose via env interpolation (docker_compose_raw must stay constant)."
}

variable "log_host_path" {
  type        = string
  description = "Host directory bind-mounted into every app process at /var/www/html/var/log (the one filesystem write left after moving the private/public filesystems to S3). MUST be unique per environment whenever prod and staging point at the same server; harmless when they're on separate servers. Empty string disables the bind mount (logs stay ephemeral in-container)."
  default     = ""
}

variable "basic_auth_host_path" {
  type        = string
  description = "Host directory bind-mounted into the web app at /var/www/auth, holding the .htpasswd that the staging basic-auth image (final-protected) reads (see shopware/docker/nginx-basic-auth). A DIRECTORY mount, not a single file — coolify_storage has no file-content field and a bare single-file mount is created as a dir when absent. Create the dir + .htpasswd out-of-band and chown 82 (like the var/log dir). Empty string => no mount (production uses final-prod, which carries no basic-auth config)."
  default     = ""
}

variable "s3" {
  type = object({
    bucket_private = string # S3_BUCKET_PRIVATE
    bucket_public  = string # S3_BUCKET_PUBLIC
    region         = string # S3_REGION
    endpoint       = string # S3_DOMAIN (e.g. https://nbg1.your-objectstorage.com)
    cdn_domain     = optional(string, "")
    # In-bucket path prefix (S3_ROOT_PREFIX). null => auto "<environment_name>/" so
    # environments can share one bucket without colliding. "" => bucket root (use a
    # dedicated bucket per env). Any other value is used verbatim (trailing / added).
    path_prefix = optional(string, null)
  })
  description = "S3 object storage for the private/public filesystems (shopware/config/packages/shopware.yaml). Credentials are in var.secrets (s3_access_key_id / s3_secret_access_key)."
}

variable "secrets" {
  type = object({
    app_secret           = string
    instance_id          = string
    rabbitmq_password    = string
    s3_access_key_id     = string
    s3_secret_access_key = string
    # Backup-bucket credentials (offsite mirror + DB dump target). Optional so a stack
    # with enable_backup = false still validates/applies; REQUIRED when enable_backup = true.
    s3_backup_access_key_id     = optional(string, "")
    s3_backup_secret_access_key = optional(string, "")
    # Mailpit web-UI basic auth (MP_UI_AUTH), used when enable_mailpit = true. Space-separated
    # "user:password" pair(s). Empty => Mailpit UI unauthenticated.
    mailpit_ui_auth = optional(string, "")
  })
  sensitive = true
}
