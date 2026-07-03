# var/log host bind mount for the WEB app (the one filesystem write left after moving the
# private/public filesystems to S3). monolog's rotating_file handler writes
# prod-<LOG_CHANNEL>.log under var/log; the same host dir is bind-mounted into the
# workers/scheduler service too (workers.tf, via long-form `type: bind`) so all processes
# share it and their logs show up together in the Shopware admin.
#
# Only the web app is a coolify_application_docker_image, so only it uses coolify_storage —
# coolify_storage does NOT attach to service containers (see workers.tf / FINDINGS). Guarded
# by var.log_host_path: empty string => no bind mount, logs stay ephemeral in-container.
resource "coolify_storage" "app_logs" {
  for_each = var.log_host_path == "" ? {} : local.app_env_targets

  name             = "${each.key}-var-log"
  application_uuid = each.value
  host_path        = var.log_host_path
  mount_path       = "/var/www/html/var/log"
}

# .htpasswd for the staging basic-auth image (nginx-basic-auth/basic-auth.inc reads
# /var/www/auth/.htpasswd). A DIRECTORY bind mount holding the file — coolify_storage has
# no file-content field, and a single-file bind mount would be created as a directory when
# the host path is absent, breaking auth_basic_user_file. The host dir + .htpasswd are
# created out-of-band and chown 82 (same discipline as the var/log dir). Guarded by
# var.basic_auth_host_path: empty => no mount (production runs final-prod, no basic-auth).
resource "coolify_storage" "basic_auth" {
  for_each = var.basic_auth_host_path == "" ? {} : local.app_env_targets

  name             = "${each.key}-basic-auth"
  application_uuid = each.value
  host_path        = var.basic_auth_host_path
  mount_path       = "/var/www/auth"
}
