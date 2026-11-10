#!/bin/sh
# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
# The litestream sidecar's two jobs, run by docker-compose.yml: `start` refuses an unconfigured bucket, `health [max-lag-seconds]` fails when the replica falls behind the database.
set -eu

config=/sidecar/litestream.yml
db=/data/slimm.db

case "${1:-}" in
start)
    : "${LITESTREAM_S3_BUCKET:?LITESTREAM_S3_BUCKET is empty; set it in .env to a bucket that already exists}"
    : "${LITESTREAM_ACCESS_KEY_ID:?LITESTREAM_ACCESS_KEY_ID is empty; set it in .env}"
    : "${LITESTREAM_SECRET_ACCESS_KEY:?LITESTREAM_SECRET_ACCESS_KEY is empty; set it in .env}"
    exec litestream replicate -config "$config"
    ;;
health)
    table="$(litestream generations -config "$config" "$db" 2>&1)"
    printf '%s\n' "$table" | awk -v max="${2:-300}" '
        # Go durations such as 1h2m3s, 1.5s or -6ms; a negative or sub-second lag counts as zero.
        function seconds(d,    total, n) {
            total = 0
            if (substr(d, 1, 1) == "-") return 0
            while (match(d, /^[0-9.]+(ms|us|ns|h|m|s)/)) {
                n = substr(d, 1, RLENGTH)
                if (n ~ /(ms|us|ns)$/) { d = substr(d, RLENGTH + 1); continue }
                if (n ~ /h$/) total += n * 3600
                else if (n ~ /m$/) total += n * 60
                else total += n
                d = substr(d, RLENGTH + 1)
            }
            return total
        }
        # A generation row ends in its last-update timestamp; the header and any log line do not.
        NF == 5 && $5 ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-/ && $5 > newest { newest = $5; lag = seconds($3); found = 1 }
        END {
            if (!found) { print "no replica generation yet" > "/dev/stderr"; exit 1 }
            if (lag > max) { printf "replica is %d seconds behind the database, limit %d\n", lag, max > "/dev/stderr"; exit 1 }
        }' || {
        printf '%s\n' "$table" >&2
        exit 1
    }
    ;;
*)
    echo "usage: sidecar.sh start | sidecar.sh health [max-lag-seconds]" >&2
    exit 2
    ;;
esac
