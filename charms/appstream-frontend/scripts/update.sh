#!/bin/sh

set -e
set -u

BASE_DIR=${HOME}

LOG_BASE_DIR=${BASE_DIR}/sync-logs

# Start logging
logdir="${LOG_BASE_DIR}/$(date "+%Y/%m")"
mkdir -p "${logdir}"
NOW=$(date "+%d")
LOGFILE="${logdir}/${NOW}.log"
exec >> "${LOGFILE}" 2>&1

find "${logdir}" -type f -not -path "${LOGFILE}" -not -name \*.gz -exec gzip -9 {} \;

rsync -aqzP --delete --delete-after "${RSYNC_ADDRESS:?}::www" /home/ubuntu/appstream
rsync -aqzP --delete --delete-after "${RSYNC_ADDRESS:?}::logs" /home/ubuntu/logs

# finish logging
exec > /dev/null 2>&1

sed -i '/^$/d' "${LOGFILE}"
