#!/bin/sh
# Install the meshtest test CA into the system trust store, then exec the
# command provided by docker-compose `command:`. Runs as root at start.
set -e
if [ -f /certs/ca.crt ]; then
    cp /certs/ca.crt /usr/local/share/ca-certificates/meshtest-ca.crt
    update-ca-certificates >/dev/null 2>&1 || \
        cat /certs/ca.crt >> /etc/ssl/certs/ca-certificates.crt
fi
exec "$@"
