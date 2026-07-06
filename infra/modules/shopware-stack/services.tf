# RabbitMQ and ElasticSearch are defined via `docker_compose_raw` (NOT the catalog
# `type`) so we fully control the compose and omit Coolify's SERVICE_FQDN magic — i.e.
# no auto-generated public URL; both stay internal-only on the Coolify network.
#
# Two constraints shaped this:
#  - `docker_compose_raw` must be a CONSTANT string. A `var.`-interpolated value reads
#    as "unknown" and trips the provider's "one of type / docker_compose_raw" validator
#    at `tofu validate` (same quirk that forced literal `type` before). So the RabbitMQ
#    password is NOT baked into the YAML — it's injected as a service env var below and
#    referenced as $${RABBITMQ_PASSWORD}.
#  - `connect_to_docker_network` is left unset (the provider can't round-trip `true`).
#    If apps can't reach these by hostname, toggle the predefined network in the UI.

resource "coolify_service" "rabbitmq" {
  name             = "rabbitmq"
  project_uuid     = var.project_uuid
  server_uuid      = var.server_uuid
  environment_name = var.environment_name
  instant_deploy   = true

  docker_compose_raw = <<-YAML
    services:
      rabbitmq:
        image: rabbitmq:3.13-management
        restart: unless-stopped
        environment:
          - RABBITMQ_DEFAULT_USER=shopware
          - RABBITMQ_DEFAULT_PASS=$${RABBITMQ_PASSWORD}
          - RABBITMQ_DEFAULT_VHOST=/
        # Management UI exposed on a host port (AMQP 5672 stays internal). Host port is
        # per-env, injected via RABBITMQ_MGMT_PORT below — docker_compose_raw must be a
        # constant string, so the value comes through compose env interpolation, not var.
        ports:
          - "$${RABBITMQ_MGMT_PORT}:15672"
        volumes:
          - rabbitmq-data:/var/lib/rabbitmq
    volumes:
      rabbitmq-data:
  YAML
}

# The coolify provider cannot set connect_to_docker_network (it sends `true` but reads
# back `false` → "Provider produced inconsistent result after apply", so we omit it and
# the service is created on its OWN compose network — unreachable by the apps' `rabbitmq`
# DSN host). This closes that gap declaratively: right after the service is created, flip
# the flag via the Coolify API and restart it so the container rejoins the shared
# predefined network. Keyed on the service UUID, so it runs on (re)create only — a fresh
# `tofu apply` self-corrects without any manual UI toggle. Needs `curl` on the tofu host.
resource "null_resource" "rabbitmq_connect_network" {
  triggers = {
    service_uuid = coolify_service.rabbitmq.uuid
  }

  provisioner "local-exec" {
    interpreter = ["/bin/sh", "-c"]
    environment = {
      EP   = var.coolify_endpoint
      TOK  = var.coolify_token
      UUID = coolify_service.rabbitmq.uuid
    }
    command = local.connect_network_cmd
  }
}

# Service env vars injected here (variables ARE allowed — only docker_compose_raw is
# subject to the validator quirk). The compose references both via env interpolation:
# RABBITMQ_PASSWORD (the default password) and RABBITMQ_MGMT_PORT (the host port for the
# management UI ports mapping).
resource "coolify_envs_bulk" "rabbitmq_secret" {
  resource_type = "service"
  resource_uuid = coolify_service.rabbitmq.uuid
  variables = {
    RABBITMQ_PASSWORD  = var.secrets.rabbitmq_password
    RABBITMQ_MGMT_PORT = tostring(var.rabbitmq_mgmt_port)
  }
}

resource "coolify_service" "elasticsearch" {
  count            = var.enable_elasticsearch ? 1 : 0
  name             = "elasticsearch"
  project_uuid     = var.project_uuid
  server_uuid      = var.server_uuid
  environment_name = var.environment_name
  instant_deploy   = true

  docker_compose_raw = <<-YAML
    services:
      elasticsearch:
        image: elasticsearch:8.15.0
        restart: unless-stopped
        environment:
          - discovery.type=single-node
          - xpack.security.enabled=false
          - ES_JAVA_OPTS=-Xms512m -Xmx512m
        volumes:
          - elasticsearch-data:/usr/share/elasticsearch/data
    volumes:
      elasticsearch-data:
  YAML
}

# elasticsearch is a docker_compose_raw service → same connect_to_docker_network gap as
# rabbitmq/workers: flip it via the API + restart so web/workers reach it at
# elasticsearch-<uuid>:9200 (OPENSEARCH_URL, locals.tf).
resource "null_resource" "elasticsearch_connect_network" {
  count = var.enable_elasticsearch ? 1 : 0

  triggers = {
    service_uuid = coolify_service.elasticsearch[0].uuid
  }

  provisioner "local-exec" {
    interpreter = ["/bin/sh", "-c"]
    environment = {
      EP   = var.coolify_endpoint
      TOK  = var.coolify_token
      UUID = coolify_service.elasticsearch[0].uuid
    }
    command = local.connect_network_cmd
  }
}

resource "coolify_application_docker_image" "mailpit" {
  count            = var.enable_mailpit ? 1 : 0
  name             = "mailpit"
  project_uuid     = var.project_uuid
  server_uuid      = var.server_uuid
  environment_name = var.environment_name
  docker_image     = "axllent/mailpit:v1.30.3"
  ports_exposes    = "8025,1025"
  # Stable DNS alias on the shared network so web/workers can reach SMTP at a fixed name.
  # Without it, only the "<uuid>-<deploy-id>" container name resolves — never the bare uuid —
  # and MAILER_DSN (locals.tf, local.mailpit_host) can't connect. Keep in sync with that local.
  custom_network_aliases = local.mailpit_host
  # Public FQDN for the web UI → Traefik routes it to Mailpit's 8025 (the :8025 suffix, same
  # form as the web app's domains). Omitted when mailpit_domain is empty (internal-only).
  domains              = var.mailpit_domain == "" ? null : "${var.mailpit_domain}:8025"
  health_check_enabled = false # mailpit UI is on 8025, not the default-checked port
  instant_deploy       = true
}

# Gate the Mailpit web UI behind basic auth using Mailpit's native MP_UI_AUTH (works behind a
# TLS-terminating proxy — no fragile Traefik-label wiring). Only created when a credential is
# set; without it the UI is open. Env change needs a redeploy like every other envs_bulk.
resource "coolify_envs_bulk" "mailpit" {
  count         = var.enable_mailpit && var.secrets.mailpit_ui_auth != "" ? 1 : 0
  resource_type = "application"
  resource_uuid = coolify_application_docker_image.mailpit[0].uuid
  variables = {
    MP_UI_AUTH = var.secrets.mailpit_ui_auth
  }
}
