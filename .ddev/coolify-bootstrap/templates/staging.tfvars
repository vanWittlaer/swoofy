#ddev-generated
# Staging environment settings (non-secret). See production.tfvars for the project-wide values.

staging = {
  web_image         = "ghcr.io/you/app/stage"
  web_image_tag     = "latest"
  web_domain        = "https://staging.example.com"
  app_env           = "stage"
  app_debug         = "1"
  monolog_log_level = "debug"

  enable_elasticsearch = true
  enable_mailpit       = true
  mailpit_domain       = "https://mailpit.staging.example.com"
  enable_backup        = true
  backup = {
    s3_backup_bucket = "myshop-backup"
    s3_backup_region = "hel1"
    s3_backup_domain = "https://hel1.your-objectstorage.com"
    s3_backup_path   = "staging"
  }

  # Applied via the Coolify UI post-bootstrap, NOT by `up` — the provider can't push DB tuning
  # on this Coolify version (422 on the extended-fields update), so the module keeps these as
  # the intended config and you paste them into the UI. See the post-bootstrap checklist.
  # innodb_buffer_pool_size is the one host-specific knob — size it to your DB server's RAM.
  # The rest are Shopware-recommended defaults (large GROUP_CONCAT, strict sql_mode).
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

  s3 = {
    bucket_private = "myshop-private"
    bucket_public  = "myshop-public"
    region         = "hel1"
    endpoint       = "https://hel1.your-objectstorage.com"
    cdn_domain     = "https://hel1.your-objectstorage.com/myshop-public/staging/public"
  }
}
