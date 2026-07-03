# Optional backup stack (gated by enable_backup, mirroring the elasticsearch block in
# services.tf). A single-service docker_compose_raw runs the env-agnostic shell image idle on
# `tail -f /dev/null`; two coolify_scheduled_task resources `exec` the backup scripts into it
# on cron. Single compose service ⇒ the scheduled task's target container is unambiguous.
#
# Same docker_compose_raw constraints as workers.tf: constant string, image + env injected via
# coolify_envs_bulk and consumed with $${BACKUP_IMAGE} + env_file: .env. No bind mounts — the
# scripts read source/destination straight from S3 and dump to /tmp.
resource "coolify_service" "backup" {
  count            = var.enable_backup ? 1 : 0
  name             = "backup"
  project_uuid     = var.project_uuid
  server_uuid      = var.server_uuid
  environment_name = var.environment_name
  instant_deploy   = true

  docker_compose_raw = <<-YAML
    services:
      backup:
        image: $${BACKUP_IMAGE}
        restart: unless-stopped
        env_file:
          - .env
        command: ["tail", "-f", "/dev/null"]
  YAML
}

# Image ref + a least-privilege slice of the app env (DATABASE_URL + source S3 creds; see
# local.backup_app_env) plus the backup-only destination env (S3_BACKUP_*, retention), written
# by Coolify into the service .env the compose loads. The sidecar deliberately does NOT receive
# Redis/RabbitMQ DSNs, APP_SECRET, INSTANCE_ID, Elasticsearch, monolog, MAILER_DSN, etc.
resource "coolify_envs_bulk" "backup" {
  count         = var.enable_backup ? 1 : 0
  resource_type = "service"
  resource_uuid = coolify_service.backup[0].uuid
  variables = merge(local.backup_app_env, local.backup_env, {
    BACKUP_IMAGE = "${var.backup_image}:${var.backup_image_tag}"
  })
}

# Same connect_to_docker_network gap as workers/elasticsearch: flip it via the API + restart so
# the backup container reaches the DB host on the shared network (backup-db.sh's dump). Runs
# after the env is set so the restart deploys with a valid image + env.
resource "null_resource" "backup_connect_network" {
  count      = var.enable_backup ? 1 : 0
  depends_on = [coolify_envs_bulk.backup]

  triggers = {
    service_uuid = coolify_service.backup[0].uuid
  }

  provisioner "local-exec" {
    interpreter = ["/bin/sh", "-c"]
    environment = {
      EP   = var.coolify_endpoint
      TOK  = var.coolify_token
      UUID = coolify_service.backup[0].uuid
    }
    command = local.connect_network_cmd
  }
}

# DB dump → backup bucket, on cron. Absolute path so it runs regardless of the exec working dir.
resource "coolify_scheduled_task" "backup_db" {
  count        = var.enable_backup ? 1 : 0
  service_uuid = coolify_service.backup[0].uuid
  name         = "backup-db"
  command      = "/var/www/html/bin/backup-db.sh"
  frequency    = try(var.backup.db_schedule, "0 2 * * *")
}

# Source buckets → offsite mirror, on cron.
resource "coolify_scheduled_task" "backup_s3" {
  count        = var.enable_backup ? 1 : 0
  service_uuid = coolify_service.backup[0].uuid
  name         = "backup-s3"
  command      = "/var/www/html/bin/backup-s3.sh"
  frequency    = try(var.backup.s3_schedule, "30 2 * * *")
}
