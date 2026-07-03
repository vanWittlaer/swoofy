# The provider has NO shared/project-scoped variable resource (Risk V, confirmed).
# We keep the shared env DRY in HCL (one local.shared_env map) and fan it out to
# every app process; Coolify stores a copy per application.

locals {
  # Only the web app is a coolify_application_docker_image; workers/scheduler run as a
  # service (workers.tf) and get their env via coolify_envs_bulk.workers.
  app_env_targets = {
    web = coolify_application_docker_image.web.uuid
  }
}

# Per-process LOG_CHANNEL on top of the shared env: monolog's rotating_file handler
# (config/packages/prod/monolog.yaml) writes prod-<LOG_CHANNEL>.log. Giving each
# process a distinct channel (web / worker-N / scheduler) lets them all share one
# host log directory (see storage.tf) without clobbering each other's file. Left
# unset, every process would write prod-default.log.
resource "coolify_envs_bulk" "app_shared" {
  for_each      = local.app_env_targets
  resource_type = "application"
  resource_uuid = each.value
  variables     = merge(local.shared_env, { LOG_CHANNEL = each.key })
}
