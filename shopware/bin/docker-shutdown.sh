#!/usr/bin/env bash
#
# use this command to stop the workers gracefully, run it after docker-compose build
# e.g. 'docker compose -f ./shopware/docker/docker-compose.yml build && ./shopware/bin/docker-shutdown.sh <uuid>'
#
set -e

COOLIFY_WORKER_UUID=${1:-'some-invalid-uuid'}

# avoid workers being restarted after stop command
WORKERS=$(docker ps -f name="${COOLIFY_WORKER_UUID}" -q)
WORKERS=${WORKERS//$'\n'/ }
if [[ ! -z "$WORKERS" ]]; then
    echo "Updating workers to restart=no"
    WORKERS=(${WORKERS})
    for WORKER in "${WORKERS[@]}"
    do
       docker update --restart=no "$WORKER"
    done
else
    echo "No workers found"
fi

# gracefully stop workers - note this also stops the scheduler
SCHEDULER=$(docker ps -f name="scheduler-${COOLIFY_WORKER_UUID}" -q)
if [[ ! -z "$SCHEDULER" ]]; then
    echo "Stopping workers"
    docker exec -i "$SCHEDULER" "bin/console" "messenger:stop" "-n"
    # let workers finish current messages
    sleep 30
else
    echo "No scheduler container found"
fi
