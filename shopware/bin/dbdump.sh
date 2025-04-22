#!/usr/bin/env bash
#
# usage: ./bin/dbdump.sh <target file for dump>
#
# note 1) this script requires PHP and gzip
# note 2) the --skip-triggers option breaks the blue-green-deployment however is useful for re-importing on another server
#
# Trouble with generated columns?
# - See this: https://dba.stackexchange.com/questions/240882/how-to-take-mysqldump-with-generated-column
# - Though I recommend to find a compatible mysqldump client
#

TARGET=${1:-test.sql.gz}

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
DECODED=$(php -r "echo urldecode(\"$DATABASE_URL\");")
FIELDS=($(echo $(php -r "echo implode(' ', parse_url(\"$DECODED\"));")))
PROTO=${FIELDS[0]}
HOST=${FIELDS[1]}
PORT=${FIELDS[2]}
USER=${FIELDS[3]}
PASSWORD=${FIELDS[4]}
DATABASE=${FIELDS[5]#'/'}
#
echo Dumping database $DATABASE on host $HOST for user $USER into $TARGET
#
mysqldump --no-tablespaces --single-transaction --skip-triggers --no-data --set-gtid-purged=OFF \
  -u$USER -h$HOST -p$PASSWORD --port $PORT $DATABASE | gzip >$TARGET
mysqldump --no-tablespaces --single-transaction --skip-triggers --no-create-info --hex-blob --set-gtid-purged=OFF \
  --ignore-table=$DATABASE.messenger_messages \
  --ignore-table=$DATABASE.refresh_token \
  -u$USER -h$HOST -p$PASSWORD --port $PORT $DATABASE | gzip >>$TARGET
#
echo Finished dumping database $DATABASE to $TARGET
