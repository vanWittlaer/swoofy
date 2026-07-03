output "web_uuid" {
  value = coolify_application_docker_image.web.uuid
}

output "workers_service_uuid" {
  value = coolify_service.workers.uuid
}

output "mariadb_uuid" {
  value = coolify_database_mariadb.main.uuid
}

output "rabbitmq_uuid" {
  value = coolify_service.rabbitmq.uuid
}
