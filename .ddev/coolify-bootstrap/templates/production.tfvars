# Per-environment settings (non-secret). Filled in by you after `ddev coolify-bootstrap init`.
# project_name must stay in THIS file — the bootstrap command reads it from production.tfvars.

# --- Coolify project (owns both environments) ---
project_name = "MyShop"

# --- Ops/maintenance backup sidecar image (env-agnostic; pin a released tag for prod) ---
backup_image     = "ghcr.io/you/shopware-ops-shell"
backup_image_tag = "latest"

# --- Extra env vars fanned out to every app process ---
static_env = {
  TRUSTED_PROXIES = "0.0.0.0/0" # safe ONLY if the web port is reachable only via the proxy
}

# --- Host base dir for bind mounts (var/log, staging .htpasswd). "" disables the mounts ---
log_host_base = "/data/shopware"

production = {
  web_image         = "ghcr.io/you/app/prod"
  web_image_tag     = "latest"
  web_domain        = "https://shop.example.com"
  app_env           = "prod"
  app_debug         = "0"
  monolog_log_level = "error"

  enable_elasticsearch = true
  enable_mailpit       = false
  enable_backup        = true
  backup = {
    s3_backup_bucket = "myshop-backup"
    s3_backup_region = "hel1"
    s3_backup_domain = "https://hel1.your-objectstorage.com"
    s3_backup_path   = "production"
  }

  # innodb_buffer_pool_size is the one host-specific knob — size it to your DB server's RAM.
  # The rest are Shopware-recommended defaults (large GROUP_CONCAT, strict sql_mode).
  mariadb_conf = <<-CNF
    [mysqld]
    innodb_buffer_pool_size=1G
    group_concat_max_len=320000
    sql_mode=STRICT_TRANS_TABLES,NO_ZERO_IN_DATE,NO_ZERO_DATE,ERROR_FOR_DIVISION_BY_ZERO,NO_ENGINE_SUBSTITUTION
    innodb_lock_wait_timeout=120
  CNF

  # cache may evict; session must NOT (evicting it = lost sessions). Lock lives in the DB.
  redis_conf = {
    cache   = <<-CONF
      appendonly no
      save ""
      maxmemory-policy volatile-lru
    CONF
    session = <<-CONF
      appendonly yes
      maxmemory-policy allkeys-lru
    CONF
  }

  s3 = {
    bucket_private = "myshop-private"
    bucket_public  = "myshop-public"
    region         = "hel1"
    endpoint       = "https://hel1.your-objectstorage.com"
    cdn_domain     = "https://hel1.your-objectstorage.com/myshop-public/production/public"
  }
}

# --- Secrets ---
# The per-env secrets objects (secrets_production / secrets_staging, incl. server_uuid) live in a
# separate git-ignored `secrets.auto.tfvars` — copy `secrets.auto.tfvars.example` and fill it in.
