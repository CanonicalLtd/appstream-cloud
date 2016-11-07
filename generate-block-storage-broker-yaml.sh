#!/bin/sh

cat <<EOF
block-storage-broker:
        endpoint: ${OS_AUTH_URL}
        region: ${OS_REGION_NAME}
        tenant: ${OS_TENANT_NAME}
        key: ${OS_USERNAME}
        secret: ${OS_PASSWORD}
EOF
