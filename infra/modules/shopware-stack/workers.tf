# Workers + scheduler run as a docker_compose_raw SERVICE (not coolify_application_docker_image)
# because only compose exposes a first-class `entrypoint:` — and these MUST override the
# image's supervisord entrypoint to run a console command instead of the web server (Risk W).
# Mirrors shopware/docker/worker/docker-compose.yml and how rabbitmq/elasticsearch run.
#
# docker_compose_raw must be a CONSTANT string (the provider's validator quirk), so the image
# ref and the full app env are injected as service env vars (coolify_envs_bulk.workers) and
# consumed via `$${APP_IMAGE}` interpolation + `env_file: .env` (Coolify writes the service's
# env vars into that file). Each service gets a distinct LOG_CHANNEL so monolog's per-process
# log files don't clobber.
#
# Shared per-service compose bits (identical across worker-1/2/scheduler; only entrypoint +
# LOG_CHANNEL differ):
#  - stop_signal SIGTERM + stop_grace_period 120s → graceful messenger drain on redeploy
#    (finish the in-flight message before SIGKILL).
#  - long-form `type: bind` var/log mount (source $${LOG_HOST_PATH}) — the long form is what
#    stops Coolify slugifying the source into a managed named volume, so workers share web's
#    var/log and their logs show up in the Shopware admin.
resource "coolify_service" "workers" {
  name             = "workers"
  project_uuid     = var.project_uuid
  server_uuid      = var.server_uuid
  environment_name = var.environment_name
  instant_deploy   = true

  docker_compose_raw = <<-YAML
    services:
      worker-1:
        image: $${APP_IMAGE}
        restart: unless-stopped
        stop_signal: SIGTERM
        stop_grace_period: 120s
        entrypoint: ["php", "bin/console", "messenger:consume", "async", "low_priority", "--time-limit=300", "--memory-limit=512M"]
        env_file:
          - .env
        volumes:
          - type: bind
            source: $${LOG_HOST_PATH}
            target: /var/www/html/var/log
        environment:
          - LOG_CHANNEL=worker-1
      worker-2:
        image: $${APP_IMAGE}
        restart: unless-stopped
        stop_signal: SIGTERM
        stop_grace_period: 120s
        entrypoint: ["php", "bin/console", "messenger:consume", "async", "low_priority", "--time-limit=300", "--memory-limit=512M"]
        env_file:
          - .env
        volumes:
          - type: bind
            source: $${LOG_HOST_PATH}
            target: /var/www/html/var/log
        environment:
          - LOG_CHANNEL=worker-2
      scheduler:
        image: $${APP_IMAGE}
        restart: unless-stopped
        stop_signal: SIGTERM
        stop_grace_period: 120s
        entrypoint: ["php", "bin/console", "scheduled-task:run"]
        env_file:
          - .env
        volumes:
          - type: bind
            source: $${LOG_HOST_PATH}
            target: /var/www/html/var/log
        environment:
          - LOG_CHANNEL=scheduler
  YAML
}

# Image ref + the full shared app env (DATABASE_URL, REDIS_*, MESSENGER_*, S3_*, APP_*, …),
# written by Coolify into the service .env that the compose services load via env_file.
resource "coolify_envs_bulk" "workers" {
  resource_type = "service"
  resource_uuid = coolify_service.workers.uuid
  variables = merge(local.shared_env, {
    APP_IMAGE = "${var.web_image}:${var.web_image_tag}"
    # Host path for the workers' var/log bind mount (long-form `type: bind` in the compose).
    LOG_HOST_PATH = var.log_host_path
  })
}

# Same connect_to_docker_network gap as rabbitmq: the provider can't set it, so the service
# lands on its own compose network and can't reach the DBs or rabbitmq. Flip it via the API
# and restart so the workers join the shared predefined network. Runs after the env is set
# so the restart deploys with a valid image + env.
resource "null_resource" "workers_connect_network" {
  depends_on = [coolify_envs_bulk.workers]

  triggers = {
    service_uuid = coolify_service.workers.uuid
  }

  provisioner "local-exec" {
    interpreter = ["/bin/sh", "-c"]
    environment = {
      EP   = var.coolify_endpoint
      TOK  = var.coolify_token
      UUID = coolify_service.workers.uuid
    }
    command = local.connect_network_cmd
  }
}
