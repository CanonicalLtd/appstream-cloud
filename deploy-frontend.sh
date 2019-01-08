#!/bin/bash

# The frontend is apache2 units load balanced by haproxy, with the data
# supplied by appstream-frontend subordinate charm in this repo
#
# I'm sure this would be easy with Mojo but I don't know it to do that.
# - Iain Lane 2016-03-10

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

    echo "deploying subordinate charms to $1"
    if ! juju status "${1}" | grep -q ksplice; then
        juju add-relation ksplice "$1"
    fi

    if ! juju status "${1}" | grep -q landscape; then
        juju add-relation landscape-client "$1"
    fi

    if ! juju status "${1}" | grep -q nrpe-external-master; then
        juju add-relation nrpe-external-master "$1"
    fi

    wait_deployed "$1"
}

checkout() {
    #
    # install/update basenode into charms
    #
    [ -d "$MYDIR/charms/trusty/landscape-client" ] || bzr checkout --lightweight lp:charms/trusty/landscape-client "$MYDIR/charms/trusty/landscape-client"
    [ -d "$MYDIR/charms/trusty/ksplice" ] || { echo "Please check out ksplice charm to $MYDIR/charms/trusty"; exit 1; }
    [ -d "$MYDIR/charms/trusty/nrpe-external-master" ] || { echo "Please check out nrpe-external-master charm to ${MYDIR}/charms/trusty"; exit 1; }
    [ -d "$MYDIR/charms/trusty/apache2" ] || bzr checkout --lightweight lp:charms/trusty/apache2 "$MYDIR/charms/trusty/apache2"
    [ -d "$MYDIR/charms/trusty/haproxy" ] || bzr checkout --lightweight lp:charms/trusty/haproxy "$MYDIR/charms/trusty/haproxy"

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
        if ! grep "charm-pre-install" $charmdir/hooks/install; then
            fn=$(mktemp)
            awk "/^set/ {print \$0 RS \"juju-log 'Invoking charm-pre-install hooks'\" RS \"[ -d exec.d ] && ( for f in exec.d/*/charm-pre-install; do [ -x \$f ] && /bin/sh -c \$f; done )\";next}1" $charmdir/hooks/install > $fn
            mv $fn $charmdir/hooks/install
            chmod a+x $charmdir/hooks/install
        fi
    done
}

upgrade() {
    juju upgrade-charm --repository=charms/ apache2
    wait_deployed apache2
    juju upgrade-charm --repository=charms/ haproxy
    wait_deployed haproxy
    juju upgrade-charm --repository=charms/ appstream-frontend
    wait_deployed appstream-frontend
}

extra_prodstack_configuration() {
    if [ -z "${PRODSTACK}" ]; then
        return
    fi
    if ! juju status | grep -q ksplice:; then
        juju deploy --repository "$MYDIR/charms" local:trusty/ksplice
        juju set ksplice accesskey=$(cat /srv/mojo/LOCAL/mojo-${PROJECT}/canonical-is-ksplice.key)
        juju set ksplice source=""
    fi
    if ! juju status | grep -q landscape-client:; then
        cat <<EOF >> "$CONFIG_YAML"
landscape-client:
  url: https://landscape.is.canonical.com/message-system
  ping-url: http://landscape.is.canonical.com/ping
  account-name: standalone
  registration-key: $(cat /srv/mojo/LOCAL/mojo-${PROJECT}/canonical-is-landscape.key)
  tags: juju-managed, devops-instance, devops-production
EOF
        juju deploy --repository "${MYDIR}/charms" --config "${CONFIG_YAML}" local:trusty/landscape-client
    fi

    if ! juju status | grep -q nrpe-external-master:; then
        cat <<EOF >> "${CONFIG_YAML}"
nrpe-external-master:
  nagios_master: wendigo.canonical.com
  nagios_host_context: ${PROJECT}
EOF
        juju deploy --config "${CONFIG_YAML}" --repository "$MYDIR/charms" local:trusty/nrpe-external-master
        # nagios wants to ping us
        nova secgroup-add-rule juju-${PROJECT} icmp -1 -1 0.0.0.0/0
    fi

    #
    # deploy bootstrap-node charm
    #

    if ! juju status | grep -q bootstrap-node:; then
        if [ "$(juju get-environment default-series)" != "trusty" ]; then
                echo "default-series must be trusty; run juju set-environment default-series=trusty and re-bootstrap"
                exit 1
        fi
        juju deploy --repository "${MYDIR}/charms" --to 0 local:trusty/bootstrap-node
        wait_deployed "bootstrap-node"
    fi
    subordinate_charms "bootstrap-node"

    subordinate_charms "apache2"

    subordinate_charms "haproxy"
}

if [ -z "$OS_PASSWORD" ]; then
    echo "OS_PASSWORD not set in environment, please source nova rc"
    exit 1
fi

CONFIG_YAML=$(mktemp)
trap "rm ${CONFIG_YAML}" EXIT INT QUIT HUP PIPE TERM

if [ ! -e "config.yaml" ]; then
    echo "WARNING: No config.yaml file: creating an empty one."
    touch config.yaml
fi

if [ -z "${IP}" ]; then
    echo "ERROR: \$IP is not set."
    exit 1
fi

if juju status appstream-frontend | grep -q 'agent-state:'; then
    echo 'WARNING: appstream-frontend already deployed, skipping'
    APPSTREAM_FRONTEND_ALREADY_DEPLOYED=1
else
    if ! juju status | grep -q apache2:; then
        # autoindex is here by default - we want that, so have to override the setting
        cat <<EOF >> "${CONFIG_YAML}"
apache2:
  disable_modules: status
EOF
      juju deploy ---config "${CONFIG_YAML}" -num-units=2 --constraints "root-disk=50G" --repository "$MYDIR/charms" local:trusty/apache2
      DEPLOYED_APACHE=1
    fi

    if ! juju status | grep -q haproxy:; then
      juju deploy --config "${CONFIG_YAML}" --repository "$MYDIR/charms" local:trusty/haproxy
      DEPLOYED_HAPROXY=1
    fi

    wait_deployed apache2
    wait_deployed haproxy

    if [ -n "${DEPLOYED_APACHE}${DEPLOYED_HAPROXY}" ]; then
      juju add-relation apache2:website haproxy:reverseproxy
    fi

    juju deploy --repository "${MYDIR}/charms" --config=config.yaml local:trusty/appstream-frontend
    juju add-relation appstream-frontend apache2

    wait_deployed apache2
    DEPLOYED_APPSTREAM_FRONTEND=1
fi

if [ -n "${DEPLOYED_APPSTREAM_FRONTEND}" ]; then
    wait_deployed haproxy # set $juju_status
    env="$(echo "$juju_status" | awk '/^environment:/ { print $2 }')"
    machine_no="$(echo "$juju_status" | grep machine: | grep -o '[0-9]\+')"
    machine=juju-${env}-machine-${machine_no}
    if [ -n "${IP}" ]; then
        nova floating-ip-associate ${machine} ${IP}
    fi
    juju expose haproxy
    extra_prodstack_configuration
    echo "Done."
fi

if [ -n "${APPSTREAM_FRONTEND_ALREADY_DEPLOYED}" ]; then
    checkout
    upgrade
    extra_prodstack_configuration
fi
