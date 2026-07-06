# Staging environment settings (non-secret). Secrets live in secrets.auto.tfvars.
staging = {
  web_image         = "ghcr.io/vanwittlaer/swoofy/stage"
  web_image_tag     = "latest"
  web_domain        = "https://swoofy-staging.my-demo.shop"
  app_env           = "stage"
  app_debug         = "1"
  monolog_log_level = "debug"

  # Infra toggles (per-env). ES on for staging too (same one-time index build as prod).
  # Mailpit on: staging captures outbound mail in-project instead of sending real email.
  enable_elasticsearch = true
  enable_mailpit       = true
  # Mailpit web-UI domain (Traefik routes it to :8025); gated by MP_UI_AUTH in secrets_staging.
  mailpit_domain = "https://swoofy-mailpit.my-demo.shop"
  enable_backup  = true
  backup = {
    s3_backup_bucket = "swoofy-backup"
    s3_backup_region = "hel1"
    s3_backup_domain = "https://hel1.your-objectstorage.com"
    s3_backup_path   = "staging"
  }

  mariadb_conf = <<-CNF
    [mysqld]
    innodb_buffer_pool_size=500M
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

  # Per-env runtime knobs read by the Shopware base image (php-fpm pool + php.ini), merged over
  # the shared static_env. Same as production for now; tune down here if staging is leaner.
  static_env = {
    FPM_PM_MAX_CHILDREN      = "5"
    FPM_PM_START_SERVERS     = "2"
    FPM_PM_MIN_SPARE_SERVERS = "1"
    FPM_PM_MAX_SPARE_SERVERS = "3"
    FPM_PM_MAX_REQUESTS      = "0"
    PHP_MAX_UPLOAD_SIZE      = "128m"
    PHP_MAX_EXECUTION_TIME   = "300"
    PHP_MEMORY_LIMIT         = "512m"
  }

  # S3 object storage (credentials are in secrets.auto.tfvars). Shares production's
  # buckets — isolation comes from the auto "staging/" in-bucket prefix (path_prefix
  # defaults to "<env>/"). Set path_prefix = "" here to instead use a dedicated bucket.
  s3 = {
    bucket_private = "swoofy-private"
    bucket_public  = "swoofy-public"
    region         = "hel1"
    endpoint       = "https://hel1.your-objectstorage.com"
    cdn_domain     = "https://hel1.your-objectstorage.com/swoofy-public/staging/public"
  }
}
