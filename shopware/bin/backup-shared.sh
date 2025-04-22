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
DATE=`date +%Y%m%d_%H%M%S`
TARGET="${SHARED_BACKUP_FOLDER}/${APP_ENV}_${DATE}.tar.gz"

mkdir -p "${SHARED_BACKUP_FOLDER}"

BACKUPS=$(find "${SHARED_BACKUP_FOLDER}" -name "*.tar.gz" | wc -l | sed 's/\ //g')
while [ $BACKUPS -ge $SHARED_BACKUPS_TO_KEEP ]; do
  ls -tr1 "${SHARED_BACKUP_FOLDER}"/*.tar.gz | head -n 1 | xargs rm -f
  BACKUPS=$(expr $BACKUPS - 1)
done

tar -C ${SHARED_BASE_FOLDER} -czf ${TARGET} files public/media public/thumbnail
