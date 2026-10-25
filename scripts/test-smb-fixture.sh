#!/bin/sh
set -eu
# A fixed image digest, loopback-only port, throwaway account and owned container; no host SMB configuration changes.
container="syncophant-smb-test-$$"
image="ghcr.io/servercontainers/samba@sha256:349779fe8c0c619407adb8dd5dc6940c807ec1bf215ef29932fa18dd287fd66e"
cleanup() { rtk proxy docker rm -f -v "$container" >/dev/null 2>&1 || true; }
trap cleanup EXIT INT TERM
rtk proxy docker run --rm -d --name "$container" -p 127.0.0.1:445:445 \
    -e ACCOUNT_fixture=test-password \
    -e 'SAMBA_VOLUME_CONFIG_test=[test]; path=/shares/test; valid users=fixture; read only = no; guest ok = no' \
    -e 'SAMBA_GLOBAL_STANZA=server min protocol = SMB3_00; server signing = mandatory; smb encrypt = required' \
    "$image" >/dev/null
rtk proxy docker exec "$container" mkdir -p /shares/test/nested
rtk proxy docker exec "$container" chmod -R 0777 /shares/test
count=0
until rtk proxy docker exec "$container" smbclient //127.0.0.1/test -U 'fixture%test-password' -c ls >/dev/null 2>&1; do
    count=$((count + 1))
    if [ "$count" -ge 30 ]; then rtk proxy docker logs --tail 30 "$container"; exit 1; fi
    rtk proxy sleep 1
done
SYNCOPHANT_SMB_FIXTURE=1 rtk proxy swift test --filter SMBIntegrationTests
