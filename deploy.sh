#!/bin/bash

MYDIR=$(dirname "$(readlink -f $0)")

VOLUMENAME=mirror
VOLUMESIZE=500 # GB

get_volume_field() {
    name=$1
    field=$2
    shift 2

    output=$(nova volume-show "${name}" 2>/dev/null | awk "BEGIN {FS=\"|\"} / ${field} / {gsub(\" \",\"\"); print \$3}")

    if [ $? -eq 0 ]; then
        echo "${output}"
    fi
}

find_or_create_volume() {
    name=$1
    size=$2
    shift 2

    display_name=$(get_volume_field "${name}" "display_name")

    if [ -z "${display_name}" ]; then
        nova volume-create --display-name "${name}" "${size}" >/dev/null 2>/dev/null
        timeout=60
        while (( timeout > 0 )); do
            status=$(get_volume_field "${name}" "status")
            case "${status}" in
                creating)
                    (( timeout -= 5 ))
                    ;;
                available)
                    echo $(get_volume_field "${name}" "id")
                    return
                    ;;
                *)
                    echo "ERROR: Creating volume \"${display_name}\" failed with status \"${status}\"" >&2
                    exit 1
                    ;;
            esac
        done
        echo "ERROR: Creating volume \"${display_name}\" timed out" >&2
        exit 1
    else
        status=$(get_volume_field "${name}" "status")
        case "${status}" in
            # We only like 'available' volumes, can't do much with errored or in-use ones
            available)
                echo $(get_volume_field "${name}" "id")
                ;;
            *)
                echo "ERROR: Volume \"${display_name}\" already exists and has status \"${status}\"" >&2
                exit 1
                ;;
        esac
    fi
}

wait_deployed() {
    echo "waiting for $1 to get deployed..."
    while true; do
        juju_status="$(juju status $1)"
        if echo "$juju_status" | grep -q 'agent-state: started' &&
           ! echo "$juju_status" | grep -q 'agent-state: pending'; then
            break
        fi
        sleep 5
    done
}

wait_attached() {
    volume=$1
    shift

    echo -n "waiting for ${volume} to be attached..."

    timeout=60
    while (( timeout > 0 )); do
        status=$(get_volume_field "${volume}" "status")
        case "${status}" in
            in-use)
                echo "done"
                return
                ;;
            *)
                (( timeout -= 5 ))
                ;;
        esac
    done

    echo "\nERROR: Attaching volume \"${volume}\" timed out" >&2
    exit 1
}

if [ -z "$OS_PASSWORD" ]; then
    echo "OS_PASSWORD not set in environment, please source nova rc"
    exit 1
fi

#
# install/update basenode into charms
#

[ -d "$MYDIR/basenode" ] || { echo "Please check out basenode into $MYDIR"; exit 1; }
for charmdir in $MYDIR/charms/trusty/*; do
    # ignore subordinate charms
    if grep -q 'subordinate:.*true' $charmdir/metadata.yaml; then
        continue
    fi
    echo "Installing basenode into $charmdir"
    rm -rf "$charmdir/exec.d/basenode"
    mkdir -p "$charmdir/exec.d"
    cp -r "$MYDIR/basenode" "$charmdir/exec.d"
done

#
# deploy bootstrap-node charm
#

if ! juju status | grep -q bootstrap-node:; then
    juju deploy --repository "${MYDIR}/charms" --to 0 local:trusty/bootstrap-node
    wait_deployed bootstrap-node
    # XXX: add this in prodstack
    #echo 'deploying subordinate charms to bootstrap-node'
    #juju add-relation ksplice bootstrap-node
    #juju add-relation landscape-client bootstrap-node
fi

if juju status appstream-dep11 | grep -q 'agent-state:'; then
    echo 'WARNING: appstream-dep11 already deployed, skipping'
else
    config_yaml=$(mktemp)
    trap "rm ${config_yaml}" EXIT INT QUIT PIPE
    # temporarily set arches to amd64 only
    cat << EOF >> "${config_yaml}"
appstream-dep11:
    ip: ${IP:-162.213.34.169}
    arches: ${ARCHES:-amd64}
    mirror: ${MIRROR:-archive.ubuntu.com}
EOF
    juju deploy --repository "${MYDIR}/charms" --config "${config_yaml}" --constraints "cpu-cores=8 mem=8G" local:trusty/appstream-dep11
    wait_deployed appstream-dep11
    # XXX: add this in prodstack
    #echo 'deploying subordinate charms to autopkgtest-cloud-worker'
    #juju add-relation ksplice appstream-dep11
    #juju add-relation landscape-client appstream-dep11
    #wait_deployed appstream-dep11
    DEPLOYED_APPSTREAM=1
fi

if [ -n "${DEPLOYED_APPSTREAM}" ]; then
    id=$(find_or_create_volume "${VOLUMENAME}" "${VOLUMESIZE}")
    env="$(echo "$juju_status" | awk '/^environment:/ { print $2 }')"
    machine_no="$(echo "$juju_status" | grep machine: | grep -o '[0-9]\+')"
    machine=juju-${env}-machine-${machine_no}
    device=$(nova volume-attach "${machine}" "${id}" auto 2>/dev/null | awk "BEGIN {FS=\"|\"} / device / {gsub(\" \",\"\"); print \$3}")
    echo "Device: ${device}"
    wait_attached "${id}"
    # this is a json array containing amongst other things a 'device' -> /dev/device mapping
    json=$(get_volume_field "${id}" "attachments")
    # run the action on all the units so that they mount the volume
    units=$(juju status | python3 -c "import sys, yaml; print (' '.join(yaml.load(sys.stdin)['services']['appstream-dep11']['units'].keys()))")
    for unit in ${units}; do
        juju action do ${unit} mirror-mounted device=${device}
    done
    nova floating-ip-associate ${machine} ${IP}
    juju expose appstream-dep11
    echo "Done. Try http://${IP}"
fi
