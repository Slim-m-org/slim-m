#!/bin/sh
# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
# A test connector: reports what the sandbox lets it see and reach, then waits.
echo "uid=$(id -u) gid=$(id -g)"
if touch /rootfs-write 2>/dev/null; then echo "rootfs=writable"; else echo "rootfs=readonly"; fi
if touch /tmp/probe 2>/dev/null; then echo "tmp=writable"; else echo "tmp=readonly"; fi
if touch /data/probe 2>/dev/null; then echo "data=writable"; else echo "data=none"; fi
for s in /var/run/docker.sock /run/docker.sock /run/runtime.sock /run/podman/podman.sock; do
  if [ -e "$s" ]; then echo "socket=$s"; fi
done
if grep -q -e docker.sock -e runtime.sock /proc/mounts; then echo "mount=runtime-socket"; fi
echo "capeff=$(awk '/^CapEff/ {print $2}' /proc/self/status)"
echo "nonewprivs=$(awk '/^NoNewPrivs/ {print $2}' /proc/self/status)"
echo "seccomp=$(awk '/^Seccomp:/ {print $2}' /proc/self/status)"
for t in $SLIMM_PROBE_CONNECT; do
  r=$(printf 'CONNECT %s HTTP/1.1\r\nHost: %s\r\n\r\n' "$t" "$t" | nc -w 3 slimm-gateway 3128 | head -n 1 | tr -d '\r')
  echo "connect $t => $r"
done
for t in $SLIMM_PROBE_DIRECT; do
  if nc -w 2 "${t%:*}" "${t##*:}" </dev/null >/dev/null 2>&1; then echo "direct $t => open"; else echo "direct $t => closed"; fi
done
for u in $SLIMM_PROBE_HTTP; do
  r=$(wget -q -T 5 -O - "$u" 2>&1 | head -n 1)
  echo "http $u => $r"
done
echo "probe=done"
exec sleep "${SLIMM_PROBE_SLEEP:-3600}"
