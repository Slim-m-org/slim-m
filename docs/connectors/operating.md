<!-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0 -->
# Running host-run connectors

A host-run connector is a connector whose image this server starts for you, in a sandbox (decision [0134](../decisions/0134-connector-runtime-supervisor.md)).
It needs the connector supervisor, a second small service that is the only thing holding the container runtime's socket.
Nothing here is on by default: a deployment without the supervisor has no host-run connectors, and admin-started connectors work as before.

## What it runs on

Only rootful Docker Engine 28.0.0 or newer, with AppArmor or SELinux applied to containers, is supported.
The supervisor checks this at start and exits with the reason otherwise:

- Docker 28.0.0 is the first engine that can make an internal network the host has no address on (gateway mode `isolated`); on older engines a connector could reach every host service listening on 0.0.0.0 through its own network's gateway address.
  It also carries the embedded-resolver fix for CVE-2024-29018.
- AppArmor is on by default on Ubuntu, Debian and openSUSE.
  On Fedora and other SELinux hosts, Docker leaves SELinux off unless `/etc/docker/daemon.json` has `"selinux-enabled": true`, and containers then run as `spc_t`, which is unconfined.
- cgroup v2 with the memory, cpu and pids controllers, and a seccomp profile that is not unconfined.

What was tried on 2026-11-23:

| Runtime | Result |
| --- | --- |
| Docker 29.10.0, Fedora 44, SELinux not enabled in the daemon | Refused at start: no AppArmor or SELinux. With that check off for the test suite only, every Docker test passes. |
| Docker 29.1.3, Ubuntu 24.04, AppArmor | Supported: the whole supervisor Docker test suite passes (`cargo test -p slimm-supervisor -- --include-ignored`), the AppArmor check included. |
| Podman 5.8.1 rootful, Fedora 44, through its Docker-compatible socket | Refused at start. Podman ignores the `isolated` gateway mode, gives the internal network a gateway on the host (10.89.0.1), and a container on it reached a host listener there; its cpu controller was also not delegated. |
| Docker 29.10.0 rootless, Ubuntu 24.04 | Refused at start: rootless Docker applies no AppArmor or SELinux profile. Its internal networks are isolated and its cgroup controllers were delegated. |

## What the sandbox is

The supervisor fixes every security setting itself; the server can choose only the image, a few `SLIMM_*` environment values, the limits, the approved hosts and whether there is a data volume.

- The image must be pinned by digest and start with one of the allowed registry prefixes (`ghcr.io/slim-m-org/` unless you widen it).
- The connector runs as user 65532 with a read-only root, all capabilities dropped, `no-new-privileges`, the runtime's default seccomp and AppArmor or SELinux profiles, private IPC, PID and UTS namespaces, an init process and no restart policy.
- Memory, CPU and process limits are always set, and a request above your ceilings is refused, never clamped.
- There are no bind mounts, devices or published ports; the only mount is the connector's own volume at `/data`.
- The volume has a ceiling the manifest asks for (default 256 MiB, at most `SLIMM_SUPERVISOR_MAX_VOLUME_MIB`, default 1024).
  A named volume has no size limit of its own, so the supervisor measures every connector volume every 30 seconds and stops a connector past its ceiling, and the server turns it off with an admin alert and an audit row.
  Between two measurements a connector can write past the ceiling for up to 30 seconds; if that matters on your host, keep Docker's data on its own filesystem.
- Each connector gets an internal network in gateway mode `isolated`, so it has no route out and the host has no address on it, and a gateway next to it that forwards only to your server's API and the `host:port` pairs the admin approved.
  The gateway refuses loopback, link-local and metadata addresses, every runtime network, your deny list, and LAN addresses unless the admin granted the Private network.
  It removes `X-Forwarded-For`, `Forwarded` and `X-Real-IP` from every request to the server and reads the request inside a `CONNECT` tunnel to it, so a connector cannot choose the address the server keys it by.
- Gateways and the volume helper run the supervisor's own image by its content id, resolved once at start.
- Every object carries `org.slim-m.managed-by=slimm-supervisor` and an instance id kept in the supervisor's state, so two deployments on one host never touch each other's connectors.

## Turning it on with docker compose

1. Generate a secret with `openssl rand -hex 32` and put it in `.env` as `SLIMM_SUPERVISOR_SECRET`.
2. Add the overlay: `COMPOSE_FILE=docker-compose.yml:docker-compose.connectors.yml`, and set `SLIMM_VERSION` to the release you run.
   The overlay refuses to start without it: the supervisor image `ghcr.io/slim-m-org/slim-m-supervisor` is published and cosign-signed with the server's images under the same tags, and the overlay never follows `latest`.
3. If the runtime's socket is not `/var/run/docker.sock`, set `SLIMM_RUNTIME_SOCKET` to it (for example `$XDG_RUNTIME_DIR/podman/podman.sock`).
4. If admins may grant connectors the Private network, put the docker host's own LAN addresses in `SLIMM_SUPERVISOR_LAN_DENY` (comma separated IPs or CIDRs).
   The supervisor has no network of its own, so it cannot see the host's addresses; every docker network it can see is denied already.
   While the list is empty the Private network cannot be granted: the install says so, and the supervisor refuses such a connector.
5. Optionally widen `SLIMM_SUPERVISOR_REGISTRIES` or change `SLIMM_SUPERVISOR_MAX_CONNECTORS`, `_MAX_MEMORY_MIB`, `_MAX_CPUS`, `_MAX_PIDS` and `_MAX_VOLUME_MIB` (defaults 8, 512, 1.0, 256 and 1024).
6. The overlay pins the egress network to `10.213.254.0/24` and sets the server's `SLIMM_TRUSTED_PROXIES` to exclude it, so the server never believes a forwarded header from a gateway.
   If that subnet collides with one of yours, change it in `docker-compose.connectors.yml` and the `!` entry together.
7. Run `docker compose up -d`.
   The supervisor checks the runtime first and exits with the reason if it cannot enforce the sandbox: the engine and its version, AppArmor or SELinux, cgroup v2 with the memory, cpu and pids controllers, a seccomp profile that is not unconfined, the egress network and an isolated internal network it can create.

The Dock then offers host-run connectors to admins.

## Bare metal

`deploy/systemd/slimm-supervisor.service` runs `/usr/local/bin/slimm-supervisor` as a `slimm-supervisor` user in the runtime's group, with the server's group (`slimm` in the unit) as its own, no network and no capabilities.
Put `SLIMM_SUPERVISOR_SECRET`, `SLIMM_SUPERVISOR_SERVER_URL`, `SLIMM_SUPERVISOR_EGRESS_NETWORK`, `SLIMM_SUPERVISOR_IMAGE` and `SLIMM_SUPERVISOR_SERVER_UID` (the server's uid) in `/etc/slimm/supervisor.env`.
Give the server `SLIMM_CONNECTOR_SUPERVISOR_SOCKET=/run/slimm-supervisor/supervisor.sock`, the same `SLIMM_SUPERVISOR_SECRET`, and `SLIMM_CONNECTOR_API_URL` set to the address connectors reach it at on the egress network.
Set the server's `SLIMM_TRUSTED_PROXIES` so it excludes the egress network (`!<its subnet>`).
Run one supervisor per deployment: a supervisor binds to the first server that names itself to it, kept in its state directory, and refuses any other.

## When something is down

- If the supervisor or the runtime is down, running connectors keep running; the Dock says the runtime is unavailable and refuses install and start until it is back.
- The server reconciles every 5 seconds: it creates what is missing with a new token, starts what should run, stops what is disabled, and removes labelled containers it has no record of, keeping their volumes.
- Uninstalling with "delete data" waits for the supervisor: if it cannot remove the container and its volume, the server answers 503, leaves the connector installed and turned off, and the admin tries again once the supervisor is back.
  Uninstalling and keeping the data never waits; a container the supervisor could not remove then is removed by the next pass, with its volume kept.
- A crashing connector is started again after 1 second, doubling to 5 minutes, and turned off after 5 crashes within 10 minutes with an admin alert and an audit row.

## Logs

The supervisor writes one JSON line per request to stdout: the verb, the connector id, the caller's uid, the outcome and the error code; never an environment value or the secret.
Each gateway writes one JSON line per allowed or refused connection to its own container log.
A connector's own output stays in the runtime's rotated log files (10 MiB times 3) and admins read it from its Dock page.
