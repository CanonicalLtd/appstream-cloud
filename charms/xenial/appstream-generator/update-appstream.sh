#!/bin/sh

set -e

BASE_DIR=/home/ubuntu/appstream

ASGEN=/snap/bin/appstream-generator
PUBLIC_DIR=${BASE_DIR}/appstream-public
WORKSPACE_DIR=${BASE_DIR}/appstream-workdir
STAMP_FILE=${BASE_DIR}/last-update
LOG_BASE_DIR=${BASE_DIR}/logs
VIRTUALENV_DIR=${BASE_DIR}/appstream
CLEAN_FILE=${BASE_DIR}/clean
FORGET_FILE=${BASE_DIR}/forget

RELEASES=$(jq -r '.Suites | keys | reduce .[] as $item ("";. + " " + $item) | ltrimstr(" ")' "${WORKSPACE_DIR}/asgen-config.json")

# Start logging
logdir="${LOG_BASE_DIR}/`date "+%Y/%m"`"
mkdir -p ${logdir}
NOW=`date "+%d_%H%M"`
LOGFILE="${logdir}/${NOW}.log"
exec >> "${LOGFILE}" 2>&1

echo "Reticulating splines"

cd ${WORKSPACE_DIR}

if [ -e "${FORGET_FILE}" ]; then
    . ${FORGET_FILE}
    for pkg in ${CLEAN_PKGS}; do
        echo "Forgetting ${pkg}"
        ${ASGEN} -w ${WORKSPACE_DIR} forget ${pkg}
    done
    rm ${FORGET_FILE}
fi

if [ -e "${CLEAN_FILE}" ]; then
    echo "Also cleaning up"
fi

for release in ${RELEASES}; do
    if [ -e "${CLEAN_FILE}" ]; then
        ${ASGEN} -w ${WORKSPACE_DIR} remove-found ${release}
    fi
    ${ASGEN} -w ${WORKSPACE_DIR} process ${release}
done

echo "Updating ${PUBLIC_DIR}"

rsync -a --verbose --delete-after "${WORKSPACE_DIR}/export/" --filter "protect media/main" --filter "protect media/universe" --filter "protect media/multiverse" --filter "protect media/restricted" --filter "protect data/xenial" --filter "protect html/xenial" "${PUBLIC_DIR}/"
touch ${STAMP_FILE}

echo "Running cleanup"
${ASGEN} -w ${WORKSPACE_DIR} cleanup

if [ -e "${CLEAN_FILE}" ]; then
    rm -rf "${WORKSPACE_DIR}/media"
    rm "${CLEAN_FILE}"
fi

echo "Compressing log files"

find "${LOG_BASE_DIR}" -type f -name \*.log ! -newermt '2 days ago' -print0 | xargs -0r xz -9

echo "Done"

# finish logging
exec > /dev/null 2>&1
