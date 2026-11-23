<!-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0 -->
# Running host-run connectors

A host-run connector is a connector whose image this server starts for you, in a sandbox (decision [0134](../decisions/0134-connector-runtime-supervisor.md)).
It needs the connector supervisor, a second small service that is the only thing holding the container runtime's socket.
Nothing here is on by default: a deployment without the supervisor has no host-run connectors, and admin-started connectors work as before.

## What the sandbox is

The supervisor fixes every security setting itself; the server can choose only the image, a few `SLIMM_*` environment values, the limits, the approved hosts and whether there is a data volume.

- The image must be pinned by digest and start with one of the allowed registry prefixes (`ghcr.io/slim-m-org/` unless you widen it).
- The connector runs as user 65532 with a read-only root, all capabilities dropped, `no-new-privileges`, the runtime's default seccomp profile, private IPC, PID and UTS namespaces, an init process and no restart policy.
- Memory, CPU and process limits are always set, and a request above your ceilings is refused, never clamped.
- There are no bind mounts, devices or published ports; the only mount is the connector's own volume at `/data`.
- Each connector gets an internal network with no route out, and a gateway next to it that forwards only to your server's API and the `host:port` pairs the admin approved.
  The gateway refuses loopback, link-local and metadata addresses, every runtime network, your deny list, and LAN addresses unless the admin granted the Private network.
- Every object carries `org.slim-m.managed-by=slimm-supervisor` and an instance id kept in the supervisor's state, so two deployments on one host never touch each other's connectors.

## Turning it on with docker compose

1. Generate a secret with `openssl rand -hex 32` and put it in `.env` as `SLIMM_SUPERVISOR_SECRET`.
2. Add the overlay: `COMPOSE_FILE=docker-compose.yml:docker-compose.connectors.yml`.
3. If the runtime's socket is not `/var/run/docker.sock`, set `SLIMM_RUNTIME_SOCKET` to it (for example `$XDG_RUNTIME_DIR/podman/podman.sock`).
4. If admins may grant connectors the Private network, put the docker host's own LAN addresses in `SLIMM_SUPERVISOR_LAN_DENY` (comma separated IPs or CIDRs).
   The supervisor has no network of its own, so it cannot see the host's addresses; every docker network it can see is denied already.
5. Optionally widen `SLIMM_SUPERVISOR_REGISTRIES` or change `SLIMM_SUPERVISOR_MAX_CONNECTORS`, `_MAX_MEMORY_MIB`, `_MAX_CPUS` and `_MAX_PIDS` (defaults 8, 512, 1.0 and 256).
6. Run `docker compose up -d`.
   The supervisor checks the runtime first and exits with the reason if it cannot enforce the sandbox: cgroup v2 with the memory, cpu and pids controllers, a seccomp profile that is not unconfined, the egress network and an internal network it can create.

The Dock then offers host-run connectors to admins.

## Bare metal

`deploy/systemd/slimm-supervisor.service` runs `/usr/local/bin/slimm-supervisor` as a `slimm-supervisor` user in the runtime's group, with the server's group (`slimm` in the unit) as its own, no network and no capabilities.
Put `SLIMM_SUPERVISOR_SECRET`, `SLIMM_SUPERVISOR_SERVER_URL`, `SLIMM_SUPERVISOR_EGRESS_NETWORK`, `SLIMM_SUPERVISOR_IMAGE` and `SLIMM_SUPERVISOR_SERVER_UID` (the server's uid) in `/etc/slimm/supervisor.env`.
Give the server `SLIMM_CONNECTOR_SUPERVISOR_SOCKET=/run/slimm-supervisor/supervisor.sock`, the same `SLIMM_SUPERVISOR_SECRET`, and `SLIMM_CONNECTOR_API_URL` set to the address connectors reach it at on the egress network.
For a rootless runtime, run the unit as the runtime's own user instead, which gives the supervisor that user's powers and no more.

## When something is down

- If the supervisor or the runtime is down, running connectors keep running; the Dock says the runtime is unavailable and refuses install and start until it is back.
- The server reconciles every 5 seconds: it creates what is missing with a new token, starts what should run, stops what is disabled, and removes labelled containers it has no record of, keeping their volumes.
- A crashing connector is started again after 1 second, doubling to 5 minutes, and turned off after 5 crashes within 10 minutes with an admin alert and an audit row.

## Logs

The supervisor writes one JSON line per request to stdout: the verb, the connector id, the caller's uid, the outcome and the error code; never an environment value or the secret.
Each gateway writes one JSON line per allowed or refused connection to its own container log.
A connector's own output stays in the runtime's rotated log files (10 MiB times 3) and admins read it from its Dock page.
