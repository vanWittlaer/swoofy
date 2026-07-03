# Credentials are left to Coolify to generate; we never see or store them. The
# app DSN is read back from the computed `internal_db_url` (see locals.tf).
resource "coolify_database_mariadb" "main" {
  name             = "mariadb"
  project_uuid     = var.project_uuid
  server_uuid      = var.server_uuid
  environment_name = var.environment_name
  image            = "mariadb:11"
  mariadb_user     = "shopware"
  mariadb_database = "shopware"
  # Optional public exposure (host port -> container 3306). Set on an existing DB this
  # goes through the Update path (SetUpdateExtendedDiff = only changed fields), so unlike
  # mariadb_conf it does NOT drag in the forbidden enable_ssl/is_log_drain_enabled/
  # is_include_timestamps fields. null = internal-only.
  is_public   = var.mariadb_public_port != null
  public_port = var.mariadb_public_port
  # DB tuning is DISABLED via tofu against this Coolify version. conf can only be set
  # through the provider's "extended fields" UPDATE call (Create triggers it whenever
  # MariadbConf is configured). 0.1.7 bundles enable_ssl / is_log_drain_enabled /
  # is_include_timestamps into that payload, and this Coolify API rejects them
  # (HTTP 422 "This field is not allowed"), so ANY conf value fails the update and taints
  # the DB. Forcing null skips the update entirely → clean create with a populated
  # internal_db_url. Apply my.cnf tuning in the Coolify UI until the provider/API align;
  # var.mariadb_conf (production.tfvars) is kept as the intended config. See FINDINGS.
  mariadb_conf   = null
  instant_deploy = true
}

# Two dedicated Redis instances (cache / session). Coolify generates each password;
# the DSN is read back from each instance's computed `internal_db_url`. Symfony lock
# uses the shared DB (LOCK_DSN=DATABASE_URL), so no dedicated lock Redis.
resource "coolify_database_redis" "r" {
  for_each         = toset(["cache", "session"])
  name             = "redis-${each.key}"
  project_uuid     = var.project_uuid
  server_uuid      = var.server_uuid
  environment_name = var.environment_name
  image            = "redis:7"
  # DISABLED — same forbidden-field 422 on the extended-fields update as mariadb_conf
  # (see note above). null skips the update; set redis.conf in the Coolify UI for now.
  redis_conf     = null
  instant_deploy = true
}
