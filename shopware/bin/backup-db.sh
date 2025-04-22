#!/usr/bin/env bash

set -e

CWD="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

export PROJECT_ROOT="${PROJECT_ROOT:-"$(dirname "$CWD")"}"
export ENV_FILE=${ENV_FILE:-"${PROJECT_ROOT}/.env"}

# read the local APP_ENV to be used by load_dotenv
source "${PROJECT_ROOT}/.env.local"

# shellcheck source=functions.sh
source "${PROJECT_ROOT}/bin/functions.sh"
#
curenv=$(declare -p -x)

load_dotenv "$ENV_FILE"

# Restore environment variables set globally
set -o allexport
eval "$curenv"
set +o allexport
#
DATE=$(date +%Y%m%d_%H%M%S)
TARGET="${DB_BACKUP_FOLDER}/${APP_ENV}_${DATE}.sql.gz"

mkdir -p "${DB_BACKUP_FOLDER}"

BACKUPS=$(find "${DB_BACKUP_FOLDER}" -name "*.sql.gz" | wc -l | sed 's/\ //g')
while [ $BACKUPS -ge $DB_BACKUPS_TO_KEEP ]; do
  ls -tr1 "${DB_BACKUP_FOLDER}"/*.sql.gz | head -n 1 | xargs rm -f
  BACKUPS=$(expr $BACKUPS - 1)
done

${CWD}/dbdump.sh ${TARGET}
