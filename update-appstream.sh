#!/bin/sh

set -e

PUBLIC_DIR=~/appstream-public
WORKSPACE_DIR=~/dep11
SCRIPT_DIR=~/appstream-dep11
STAMP_FILE=~/last-update
LOG_BASE_DIR=~/logs

# Start logging
logdir="${LOG_BASE_DIR}/`date "+%Y/%m"`"
mkdir -p ${logdir}
NOW=`date "+%d_%H%M"`
LOGFILE="${logdir}/${NOW}.log"
exec >> "${LOGFILE}" 2>&1

debmirror -p -h nova.clouds.archive.ubuntu.com -s main,universe,multiverse,restricted -a amd64 -d xenial,xenial-proposed --getcontents --no-check-gpg --method http /srv/mirror

. ~/appstream/bin/activate

cd ${WORKSPACE_DIR}
dep11-generator process . xenial
dep11-generator process . xenial-proposed
dep11-generator update-html .
#PYTHONPATH=${SCRIPT_DIR} ${SCRIPT_DIR}/scripts/dep11-generator process . xenial
#PYTHONPATH=${SCRIPT_DIR} ${SCRIPT_DIR}/scripts/dep11-generator process . xenial-proposed
#PYTHONPATH=${SCRIPT_DIR} ${SCRIPT_DIR}/scripts/dep11-generator update-html .

rsync -a --delete-after "${WORKSPACE_DIR}/export/" "${PUBLIC_DIR}/"
touch ${STAMP_FILE}

# finish logging
exec > /dev/null 2>&1
