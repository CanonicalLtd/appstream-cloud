#!/bin/bash

set -e

MYDIR=$(dirname "$(readlink -f $0)")
PROJECT=$(id -un)

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

subordinate_charms() {
    if ! juju status | grep -q "${1}"; then
        return
    fi

    SERIES=$(juju status "${1}" | grep series | cut -d: -f 2)

    echo "deploying subordinate charms to $1 (series: ${SERIES})"
    if ! juju status "${1}" | grep -q ksplice; then
        juju add-relation ${SERIES}-ksplice "$1"
    fi

    if ! juju status "${1}" | grep -q landscape; then
        juju add-relation ${SERIES}-landscape-client "$1"
    fi

    if ! juju status "${1}" | grep -q nrpe-external-master; then
        juju add-relation ${SERIES}-nrpe-external-master "$1"
    fi

    if ! juju status "${1}" | grep -q turku-agent; then
        juju add-relation ${SERIES}-turku-agent "$1"
    fi

    wait_deployed "$1"
}

extra_prodstack_configuration() {
    if [ -z "${PRODSTACK}" ]; then
        return
    fi
    #
    # install/update basenode into charms
    #
    [ -d "$MYDIR/charms/trusty/landscape-client" ] || bzr checkout --lightweight lp:charms/trusty/landscape-client "$MYDIR/charms/trusty/landscape-client"
    [ -d "$MYDIR/charms/trusty/ksplice" ] || { echo "Please check out ksplice charm to $MYDIR/charms/trusty"; exit 1; }
    [ -d "$MYDIR/charms/trusty/nrpe-external-master" ] || { echo "Please check out nrpe-external-master charm to ${MYDIR}/charms/trusty"; exit 1; }
    [ -d "$MYDIR/charms/trusty/turku-agent" ] || { echo "Please check out turku-agent charm to ${MYDIR}/charms/trusty"; exit 1; }
    [ -d "$MYDIR/charms/trusty/block-storage-broker" ] || { echo "Please check out block-storage-broker charm to ${MYDIR}/charms/trusty"; exit 1; }

    for charm in landscape-client ksplice nrpe-external-master turku-agent; do
            FROM=${MYDIR}/charms/xenial/${charm}
            TO=${MYDIR}/charms/trusty/${charm}
            if [ ! -d "${MYDIR}/charms/xenial/${charm}" ]; then
                    echo "Creating symlink ${FROM} -> ${TO}"
                    ln -s "${TO}" "${FROM}"
            fi
    done

    [ -d "$MYDIR/charms/xenial/storage" ] || { echo "Please check out storage charm to ${MYDIR}/charms/xenial"; exit 1; }

    [ -d "$MYDIR/basenode" ] || { echo "Please check out basenode into $MYDIR"; exit 1; }
    for charmdir in $MYDIR/charms/trusty/* $MYDIR/charms/xenial/*; do
        # ignore subordinate charms
        if grep -q 'subordinate:.*true' $charmdir/metadata.yaml; then
            continue
        fi
        echo "Installing basenode into $charmdir"
        rm -rf "$charmdir/exec.d/basenode"
        mkdir -p "$charmdir/exec.d"
        cp -r "$MYDIR/basenode" "$charmdir/exec.d"
        if ! grep "charm-pre-install" $charmdir/hooks/install; then
            fn=$(mktemp)
            awk "/^set/ {print \$0 RS \"juju-log 'Invoking charm-pre-install hooks'\" RS \"[ -d exec.d ] && ( for f in exec.d/*/charm-pre-install; do [ -x \$f ] && /bin/sh -c \$f; done )\";next}1" $charmdir/hooks/install > $fn
            mv $fn $charmdir/hooks/install
            chmod a+x $charmdir/hooks/install
        fi
    done

    for series in trusty xenial; do
        if ! juju status | grep -q ${series}-ksplice:; then
            juju deploy --repository "$MYDIR/charms" local:${series}/ksplice ${series}-ksplice
            juju set ${series}-ksplice accesskey=$(cat /srv/mojo/LOCAL/mojo-${PROJECT}/canonical-is-ksplice.key)
            juju set ${series}-ksplice source="http://www.ksplice.com/apt ${series} ksplice"
        fi
        if ! juju status | grep -q ${series}-landscape-client:; then
            cat <<EOF >> "$CONFIG_YAML"
${series}-landscape-client:
  url: https://landscape.is.canonical.com/message-system
  ping-url: http://landscape.is.canonical.com/ping
  account-name: standalone
  registration-key: $(cat /srv/mojo/LOCAL/mojo-${PROJECT}/canonical-is-landscape.key)
  tags: juju-managed, devops-instance, devops-production
EOF
            juju deploy --repository "${MYDIR}/charms" --config "${CONFIG_YAML}" local:${series}/landscape-client ${series}-landscape-client
        fi

        if ! juju status | grep -q ${series}-nrpe-external-master:; then
            cat <<EOF >> "${CONFIG_YAML}"
${series}-nrpe-external-master:
  nagios_master: wendigo.canonical.com
  nagios_host_context: ${PROJECT}
EOF
            juju deploy --config "${CONFIG_YAML}" --repository "$MYDIR/charms" local:${series}/nrpe-external-master ${series}-nrpe-external-master
            # nagios wants to ping us (|| true because the rule might be added already; could robustify that)
            nova secgroup-add-rule juju-${PROJECT} icmp -1 -1 0.0.0.0/0 || true
        fi
        if ! juju status | grep -q ${series}-turku-agent: && [ -e "${HOME}/turku.key" ]; then
            cat <<EOF >> "${CONFIG_YAML}"
${series}-turku-agent:
        api_url: https://turku.admin.canonical.com/v1
        api_auth: $(cat ${HOME}/turku.key)
        environment_name: ${PROJECT}
EOF
            juju deploy --config "${CONFIG_YAML}" --repository "$MYDIR/charms" local:${series}/turku-agent ${series}-turku-agent
        fi
    done

    #
    # deploy bootstrap-node charm
    #

    if ! juju status | grep -q bootstrap-node:; then
        juju deploy --repository "${MYDIR}/charms" --to 0 local:xenial/bootstrap-node
        wait_deployed "bootstrap-node"
    fi

    if ! juju status | grep -q block-storage-broker:; then
            $MYDIR/generate-block-storage-broker-yaml.sh >> "${CONFIG_YAML}"
            juju deploy --config "${CONFIG_YAML}" --repository "$MYDIR/charms" local:trusty/block-storage-broker
            wait_deployed "block-storage-broker"
    fi

    subordinate_charms "bootstrap-node"

    subordinate_charms "appstream-generator"

    subordinate_charms "block-storage-broker"
}

if [ -z "$OS_PASSWORD" ]; then
    echo "OS_PASSWORD not set in environment, please source nova rc"
    exit 1
fi

CONFIG_YAML=$(mktemp)
trap "rm ${CONFIG_YAML}" EXIT INT QUIT HUP PIPE TERM

if juju status appstream-generator | grep -q 'agent-state:'; then
    echo 'WARNING: appstream-generator already deployed, skipping'
    APPSTREAM_ALREADY_DEPLOYED=1
else
    trap "rm ${CONFIG_YAML}" EXIT INT QUIT PIPE
    # temporarily set arches to amd64 only
    cat << EOF >> "${CONFIG_YAML}"
appstream-generator:
    hostname: ${HOSTNAME:-}
    mirror: ${MIRROR:-}
EOF
    juju deploy --repository "${MYDIR}/charms" --config "${CONFIG_YAML}" --constraints "cpu-cores=8 mem=16G root-disk=50G" local:xenial/appstream-generator
    wait_deployed appstream-generator
cat <<EOF >> "${CONFIG_YAML}"
storage:
        provider: block-storage-broker
        volume_size: 50
        volume_label: ${PROJECT}-data
EOF
    juju deploy --repository "${MYDIR}/charms" --config "${CONFIG_YAML}" local:xenial/storage
    juju add-relation storage block-storage-broker
    wait_deployed block-storage-broker
    juju add-relation storage appstream-generator
    wait_deployed appstream-generator
    DEPLOYED_APPSTREAM=1
fi

if [ -n "${DEPLOYED_APPSTREAM}" ]; then
    juju expose appstream-generator
    extra_prodstack_configuration
    echo "Done. Now deploy the frontend."
fi

if [ -n "${APPSTREAM_ALREADY_DEPLOYED}" ]; then
    # XXX: could try to upgrade here?
    extra_prodstack_configuration
fi
