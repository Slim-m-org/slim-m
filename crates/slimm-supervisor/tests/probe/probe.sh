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
echo "lsm=$(tr -d '\0' </proc/self/attr/current 2>/dev/null)"
echo "seccomp=$(awk '/^Seccomp:/ {print $2}' /proc/self/status)"
for t in $SLIMM_PROBE_CONNECT; do
  r=$(printf 'CONNECT %s HTTP/1.1\r\nHost: %s\r\n\r\n' "$t" "$t" | nc -w 3 slimm-gateway 3128 | head -n 1 | tr -d '\r')
  echo "connect $t => $r"
done
echo "ipv6_disabled=$(cat /proc/sys/net/ipv6/conf/eth0/disable_ipv6 2>/dev/null || echo none)"
if [ -n "$SLIMM_PROBE_TARGETS_URL" ]; then
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    late=$(wget -q -T 5 -O - "$SLIMM_PROBE_TARGETS_URL" 2>/dev/null) && break
    sleep 1
  done
  SLIMM_PROBE_DIRECT="$SLIMM_PROBE_DIRECT $late"
fi
for t in $SLIMM_PROBE_DIRECT; do
  if nc -w 2 "${t%:*}" "${t##*:}" </dev/null >/dev/null 2>&1; then echo "direct $t => open"; else echo "direct $t => closed"; fi
done
for u in $SLIMM_PROBE_HTTP; do
  r=$(wget -q -T 5 -O - "$u" 2>&1 | head -n 1)
  echo "http $u => $r"
done
if [ -n "$SLIMM_PROBE_FORGE" ]; then
  s=$SLIMM_PROBE_FORGE
  forge='X-Forwarded-For: 6.6.6.6\r\nForwarded: for=6.6.6.6\r\nX-Real-IP: 6.6.6.6\r\n'
  inner="GET /cgi-bin/h HTTP/1.1\r\nHost: $s\r\n${forge}Connection: keep-alive\r\n\r\n"
  plain=$(printf "GET http://$s/cgi-bin/h HTTP/1.1\r\nHost: $s\r\n${forge}\r\n" | nc -w 3 slimm-gateway 3128)
  tunnel=$(printf "CONNECT $s HTTP/1.1\r\nHost: $s\r\n\r\n$inner" | nc -w 3 slimm-gateway 3128)
  for kind in plain tunnel; do
    eval "out=\$$kind"
    echo "forge $kind => seen=$(echo "$out" | grep -c HTTP_HOST) forged=$(echo "$out" | grep -c 6.6.6.6)"
  done
fi
for n in $SLIMM_PROBE_DNS; do
  out=$(nslookup "$n" 2>&1)
  case "$out" in
    *NXDOMAIN*) r=nxdomain ;;
    *SERVFAIL*|*REFUSED*|*"timed out"*|*"no servers"*) r=unanswered ;;
    *"Name:"*) r=resolved ;;
    *) r=other ;;
  esac
  echo "dns $n => $r"
done
echo "probe=done"
exec sleep "${SLIMM_PROBE_SLEEP:-3600}"
