# The web app is the only HTTP-serving resource. Workers + scheduler are NOT
# coolify_application_docker_image resources — the image ENTRYPOINT is supervisord and the
# provider has no real `entrypoint` field, so they'd boot the web server (Risk W); the
# --entrypoint workaround via custom_docker_run_options proved unreliable (containers
# booted broken and exited). They now run as a docker_compose_raw service — see workers.tf.

locals {
  web_port = "8000" # shopware/docker-base nginx serves on 8000
}

resource "coolify_application_docker_image" "web" {
  name                      = "web"
  project_uuid              = var.project_uuid
  server_uuid               = var.server_uuid
  environment_name          = var.environment_name
  docker_image              = var.web_image
  docker_registry_image_tag = var.web_image_tag
  ports_exposes             = local.web_port
  # Coolify maps the public domain to the container port via the :PORT suffix here. This
  # is only the proxy routing hint — the site is still served on 443. APP_URL (locals.tf)
  # deliberately stays port-less.
  domains = "${var.web_domain}:${local.web_port}"

  # Liveness probe: Shopware's dedicated lightweight endpoint (returns 200) on the nginx
  # container port. start_period gives the app time to boot before failures count, so a
  # slow first boot / deploy doesn't get the container killed or de-routed.
  health_check_enabled      = true
  health_check_path         = "/api/_info/health-check"
  health_check_port         = local.web_port
  health_check_scheme       = "http"
  health_check_method       = "GET"
  health_check_return_code  = 200
  health_check_start_period = 30

  # Runs after each deploy (README's documented step): installs Shopware on first deploy,
  # then migrations / plugin refresh / asset:install on subsequent deploys. Idempotent —
  # the helper only runs system:install when the system isn't installed. Only the web app
  # runs it (not workers/scheduler) to avoid concurrent install/migration races.
  post_deployment_command = "vendor/bin/shopware-deployment-helper run -n"
  instant_deploy          = true
}
