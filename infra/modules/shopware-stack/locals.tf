locals {
  # RabbitMQ creds are ours (set in services.tf): user "shopware", our secret password,
  # default vhost "/" (%2f). On Coolify's predefined network a service resolves by its
  # container_name = "<service-name>-<service-uuid>" (just like the DB DSNs use the DB
  # container uuid) — the bare "rabbitmq" only resolves inside the service's own compose
  # network, which the apps aren't on. The trailing path segment selects the queue.
  amqp_base = "amqp://shopware:${var.secrets.rabbitmq_password}@rabbitmq-${coolify_service.rabbitmq.uuid}:5672/%2f"

  # S3 in-bucket prefix: null => "<env>/" (shared-bucket isolation), "" => bucket root,
  # else verbatim. Normalise to exactly one trailing slash (or empty) so shopware.yaml's
  # "%env(S3_ROOT_PREFIX)%files" concatenation produces e.g. "production/files".
  s3_root_raw    = var.s3.path_prefix != null ? var.s3.path_prefix : var.environment_name
  s3_root_prefix = local.s3_root_raw == "" ? "" : "${trimsuffix(local.s3_root_raw, "/")}/"

  # Mail: staging uses the in-project Mailpit (SMTP on 1025); production uses the secret SMTP
  # DSN (var.mailer_dsn). Mailpit is reached by a STABLE custom network alias, not its UUID:
  # Coolify names an application container "<uuid>-<deploy-id>" and registers no bare-uuid
  # alias, so "smtp://<uuid>:1025" fails to resolve (getaddrinfo). We pin the alias on the
  # mailpit resource (services.tf, custom_network_aliases = local.mailpit_host) and address
  # that here — the two must stay in sync, hence the shared local. The alias is per-env
  # ("mailpit-<env>") so it stays unique if an adopter enables Mailpit in BOTH environments
  # and Coolify's predefined network turns out to be shared per-server rather than per-env.
  mailpit_host = "mailpit-${var.environment_name}"
  mailer_dsn   = var.enable_mailpit ? "smtp://${local.mailpit_host}:1025" : var.mailer_dsn

  # Shared local-exec for the connect_to_docker_network null_resources (rabbitmq + workers):
  # PATCH the flag on via the Coolify API + restart so the service joins the shared network.
  # Reads $EP / $TOK / $UUID from each provisioner's environment block (the provider can't set
  # connect_to_docker_network — it sends true, reads back false; see services.tf / FINDINGS).
  connect_network_cmd = <<-EOT
    set -eu
    curl -fsS -X PATCH -H "Authorization: Bearer $TOK" -H "Content-Type: application/json" \
      -d '{"connect_to_docker_network": true}' "$EP/api/v1/services/$UUID" >/dev/null
    curl -fsS -X POST -H "Authorization: Bearer $TOK" "$EP/api/v1/services/$UUID/restart" >/dev/null
  EOT

  # Elasticsearch: only wired when the ES service exists (enable_elasticsearch). Host is the
  # service container name on the shared predefined network (same form as the rabbitmq DSN);
  # try() keeps it valid when count is 0 (disabled → the env below sets *_ENABLED=0 anyway).
  es_url = var.enable_elasticsearch ? "http://elasticsearch-${try(coolify_service.elasticsearch[0].uuid, "")}:9200" : "http://localhost:9200"
  es_on  = var.enable_elasticsearch ? "1" : "0"

  computed_env = {
    # DSNs are read straight from each database's Coolify-generated, computed
    # internal_db_url — Shopware/Symfony consume these directly.
    DATABASE_URL = coolify_database_mariadb.main.internal_db_url

    REDIS_CACHE_URL   = coolify_database_redis.r["cache"].internal_db_url
    REDIS_SESSION_URL = coolify_database_redis.r["session"].internal_db_url

    # Symfony lock uses the shared DB (DoctrineDbalStore auto-creates lock_keys),
    # matching the .env-web-blueprint default — no dedicated lock Redis.
    LOCK_DSN = coolify_database_mariadb.main.internal_db_url

    MESSENGER_TRANSPORT_DSN              = "${local.amqp_base}/async"
    MESSENGER_TRANSPORT_LOW_PRIORITY_DSN = "${local.amqp_base}/low_priority"
    MESSENGER_TRANSPORT_FAILURE_DSN      = "${local.amqp_base}/failed"

    APP_SECRET        = var.secrets.app_secret
    INSTANCE_ID       = var.secrets.instance_id
    APP_URL           = var.web_domain
    APP_ENV           = var.app_env   # per-environment: "prod" (production) / "stage" (staging)
    APP_DEBUG         = var.app_debug # per-environment, set from *.tfvars
    MONOLOG_LOG_LEVEL = var.monolog_log_level
    MAILER_DSN        = local.mailer_dsn

    # Elasticsearch/OpenSearch — storefront/DAL search + admin search, both against the same
    # cluster (distinct index prefixes), gated by enable_elasticsearch. THROW_EXCEPTION=0 so a
    # down/unbuilt index falls back to the DB instead of 500ing. NB: enabling ES still needs a
    # one-time index build (`bin/console es:index` / `es:admin:index`).
    OPENSEARCH_URL                    = local.es_url
    SHOPWARE_ES_ENABLED               = local.es_on
    SHOPWARE_ES_INDEXING_ENABLED      = local.es_on
    SHOPWARE_ES_INDEX_PREFIX          = "sw"
    SHOPWARE_ES_THROW_EXCEPTION       = "0"
    ADMIN_OPENSEARCH_URL              = local.es_url
    SHOPWARE_ADMIN_ES_ENABLED         = local.es_on
    SHOPWARE_ADMIN_ES_REFRESH_INDICES = local.es_on
    SHOPWARE_ADMIN_ES_INDEX_PREFIX    = "sw-admin"
    SHOPWARE_ADMIN_ES_THROW_EXCEPTION = "0"

    # S3 object storage for the private/public filesystems (shopware.yaml). Fanned out
    # to every app process — workers/scheduler also read/write media & thumbnails.
    S3_BUCKET_PRIVATE    = var.s3.bucket_private
    S3_BUCKET_PUBLIC     = var.s3.bucket_public
    S3_REGION            = var.s3.region
    S3_DOMAIN            = var.s3.endpoint
    S3_CDN_DOMAIN        = var.s3.cdn_domain
    S3_ROOT_PREFIX       = local.s3_root_prefix
    S3_ACCESS_KEY_ID     = var.secrets.s3_access_key_id
    S3_SECRET_ACCESS_KEY = var.secrets.s3_secret_access_key
  }

  # Single source of truth fanned out to every app process (web + workers + scheduler).
  shared_env = merge(var.static_env, local.computed_env)

  # Least-privilege env for the backup sidecar: ONLY the keys the backup scripts actually read,
  # so it never receives the app's Redis/RabbitMQ DSNs, APP_SECRET, INSTANCE_ID, ES, monolog, etc.
  #   dump-db.sh / backup-db.sh -> DATABASE_URL, APP_ENV       (+ S3_BACKUP_* from backup_env)
  #   backup-s3.sh              -> the source-bucket S3_* creds (+ S3_BACKUP_* from backup_env)
  backup_app_env = {
    DATABASE_URL         = local.computed_env.DATABASE_URL
    APP_ENV              = local.computed_env.APP_ENV
    S3_ACCESS_KEY_ID     = local.computed_env.S3_ACCESS_KEY_ID
    S3_SECRET_ACCESS_KEY = local.computed_env.S3_SECRET_ACCESS_KEY
    S3_REGION            = local.computed_env.S3_REGION
    S3_DOMAIN            = local.computed_env.S3_DOMAIN
    S3_BUCKET_PUBLIC     = local.computed_env.S3_BUCKET_PUBLIC
    S3_BUCKET_PRIVATE    = local.computed_env.S3_BUCKET_PRIVATE
  }

  # Backup-only destination env, merged over backup_app_env for the backup service: the
  # destination bucket + retention knobs the scripts read. Empty map when disabled so
  # envs_bulk (count 0) is valid.
  backup_env = var.backup == null ? {} : {
    S3_BACKUP_BUCKET            = var.backup.s3_backup_bucket
    S3_BACKUP_REGION            = var.backup.s3_backup_region
    S3_BACKUP_DOMAIN            = var.backup.s3_backup_domain
    S3_BACKUP_PATH              = var.backup.s3_backup_path
    S3_BACKUP_ACCESS_KEY_ID     = var.secrets.s3_backup_access_key_id
    S3_BACKUP_SECRET_ACCESS_KEY = var.secrets.s3_backup_secret_access_key
    DB_BACKUPS_TO_KEEP          = tostring(var.backup.db_backups_to_keep)
    S3_BACKUP_RETAIN_DAYS       = tostring(var.backup.s3_backup_retain_days)
  }
}
