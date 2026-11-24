<!-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0 -->
# 0134 - Host-run connectors go through a separate supervisor that owns the container runtime socket

Status: accepted (owner, 2026-11-22); not built
Date: 2026-11-22
Extends: 0090 (requirements for host-run connectors), 0028 (bot accounts), 0035 (module or bot), 0067 (install consent), 0105 (an optional operator-run service)

## The question

Decision 0090 lets the host start and supervise connectors, and calls that the largest new attack surface in the module platform.
It left one question for its own record: does the container runtime client live inside the server process, or in a small separate supervisor?

The answer decides what an attacker who takes over the server can reach.
Whoever holds a Docker or Podman API socket can, by default, start a privileged container with the host's root filesystem mounted, which is root on the host.
The server is the internet-facing process: it parses every request, every upload and every module's output.
slim's identity is a single process (docs/STRATEGY.md), so a second process has to earn its place.

## Decision

The owner chose, on 2026-11-22, a separate supervisor process.
The supervisor is the only thing that holds the container runtime socket.
It offers the server four verbs, create, start, stop and remove, and only for containers it labelled itself.
Every security property of a connector container is fixed by the supervisor; the server can choose only the few fields listed below.

The supervisor is optional in the same way the listener (0105) and the code runner (0026) are.
A deployment that does not run it has no host-run connectors, and nothing else changes.

## Options compared

| Option | What a compromised server can do | Verdict |
| --- | --- | --- |
| In-server runtime client behind a restricted proxy | Whatever the proxy lets through. Off-the-shelf socket proxies filter by API path, not by request body, so `POST /containers/create` with `Privileged: true` and a bind of `/` passes and the attacker is root on the host. | Rejected |
| A separate supervisor that owns the socket and offers four verbs on labelled containers | Create, start, stop and remove connector containers in the fixed sandbox, from allowed images pinned by digest, within the supervisor's resource ceilings. Nothing else on the host. | **Chosen** |
| A rootless runtime only, with the server holding its socket | Anything the runtime's user can do: mount every file that user can read, including slim's own data if it is the same user, run any image, start containers on the user's network, and stop or remove every container that user runs. Bounded to one account, not to what slim intended. | Rejected |

### Why not the in-server client behind a restricted proxy

The proxies people already deploy for this, such as docker-socket-proxy, allow or deny whole API endpoints.
Allowing container create allows every field of create, and the dangerous fields (privileged, binds, devices, capabilities, host network, PID namespace, security options) all live in that one body.
A proxy that parses and rewrites the body is no longer a proxy: it is the supervisor, with the policy split between it and the server.
A runtime client in the server also puts the runtime's API, and any parsing bug in its client library, in the process that faces the internet.
It would keep slim to one process, which is the honest point in its favour, and it would save the operator one service.

### Why not a rootless runtime only

A rootless runtime is a good thing to run under the supervisor, and this record supports it (below).
On its own it moves the boundary from root to one user account, and that account usually owns more than connectors: in a typical install it is the same user that runs slim, so its volumes, database and data key are in reach.
It is also a property of how the operator installed the runtime, which slim cannot check or enforce, so the 0090 requirements (no host mounts, labelled containers only, image allowlist) would still need something in front of the socket.
Its advantage is that it needs no new code and no second service.

### Why the supervisor

The supervisor's whole input is a handful of JSON requests on a local unix socket from one known peer, which is small enough to read in full and to fuzz.
It has no network of its own, so the only way to reach it is to already be the server.
The policy lives in one place, written once, where a compromised server cannot change it.
The cost is a second process for operators who want host-run connectors, and a second binary to build and release.

## The supervisor's interface

The protocol is `supervisor/1`: HTTP/1.1 with JSON bodies over a unix domain socket.
Every request body is at most 64 KiB, parsed with unknown fields refused, and every response carries `"v": 1`.
Errors are `{"v":1,"error":"<code>","detail":"<text>"}` with codes `unauthorized`, `bad_request`, `policy` (the request asks for something the supervisor does not allow), `not_found`, `conflict`, `limit` (a ceiling would be exceeded) and `runtime_unavailable`.

### How the supervisor knows it is the server

- The socket lives in a directory only the server and the supervisor can see: a dedicated named volume in compose, `/run/slimm-supervisor` under systemd.
- The socket is mode 0660 and its group is the server's group.
- On every connection the supervisor reads the peer's credentials (`SO_PEERCRED`) and refuses any uid other than `SLIMM_SUPERVISOR_SERVER_UID` (default 65532, the server image's `nonroot`).
- Every request carries `Authorization: Bearer <secret>`, compared in constant time with the secret in `SLIMM_SUPERVISOR_SECRET` (at least 32 characters, or the supervisor refuses to start).
  The secret guards against another local process that shares the uid, and against a rootless setup where uids map in ways the peer check cannot see.
- There is no TCP listener at all; a supervisor on another host is out of scope.

### Connector ids

The server names a connector by its own UUIDv7 connector id, never by a container id.
The supervisor finds containers by its own labels, so the server cannot point a verb at a container the supervisor did not create.

### The verbs that change anything

| Verb | Request | Effect |
| --- | --- | --- |
| `POST /v1/connectors/{id}/create` | the create body below | Pulls the image by digest, creates the connector's network, gateway, volume and container, all stopped. Idempotent for the same body; a different body for an existing id is `conflict`, and an update is remove then create. |
| `POST /v1/connectors/{id}/start` | `{}` | Starts the gateway, then the container. Starting a running connector is a success. |
| `POST /v1/connectors/{id}/stop` | `{"timeout_s": <1..30, default 10>}` | Stops the container, then the gateway. Stopping a stopped connector is a success. |
| `POST /v1/connectors/{id}/remove` | `{"keep_volume": <bool>}` | Removes the container, the gateway and the network, and the volume unless `keep_volume`. Removing an unknown id is a success. |

The create body is the whole of what the server may choose:

```json
{
  "image": "ghcr.io/slim-m-org/example-connector@sha256:<64 hex>",
  "env": {"SLIMM_API_URL": "http://server:8080", "SLIMM_TOKEN": "<the connector's bot token>"},
  "limits": {"memory_mib": 128, "cpus": 0.5, "pids": 64},
  "egress": [{"host": "api.example.com", "port": 443}],
  "egress_private": false,
  "volume": true
}
```

- `image` must be `<registry>/<path>@sha256:<digest>`, with no tag, and must start with one of the prefixes in `SLIMM_SUPERVISOR_REGISTRIES` (default `ghcr.io/slim-m-org/`).
  Pulls are anonymous; private registries are out of scope.
- `env` keys must match `^SLIMM_[A-Z0-9_]{1,48}$`, values are at most 4 KiB each and 16 KiB in total.
  The connector's settings and secret values come over its authenticated API (the manifest card), not through the environment.
- `limits` are each optional and default to 128 MiB, 0.5 CPU and 64 processes; any value above the supervisor's ceiling is `limit`, never silently clamped.
- `egress` is the list the admin approved at install, at most 32 entries, hostnames or literal IPs with a port.
  The server's own API address (`SLIMM_SUPERVISOR_SERVER_URL`) is always allowed and need not be listed.
- `egress_private` is the connector's Private network approval, the same switch modules have for `net.fetch` (docs/OPERATING.md).
  Without it the gateway refuses every private, loopback and link-local address, even one a listed hostname resolves to.
  With it, a listed host may be on the LAN, but the supervisor's own deny list still applies.
- `volume` asks for the connector's data volume at `/data`.

### The reads

The host has to show health and logs and restart a crashed connector (0090), so the supervisor also answers three reads.
They change nothing and see only containers the supervisor labelled.

| Read | Answer |
| --- | --- |
| `GET /v1/hello` | `protocol`, `version`, `runtime` (`docker` or `podman`), `rootless`, the ceilings, the registry prefixes, and the count of connectors. |
| `GET /v1/connectors` | For each labelled connector: `id`, `state` (`created`, `running`, `exited`, `missing`), `exit_code`, `oom_killed`, `started_at`, `finished_at`, `image`. |
| `GET /v1/connectors/{id}/logs?tail=<n>&since=<unix s>` | The container's stdout and stderr, at most 1000 lines and 256 KiB, as `{"lines": [{"ts", "stream", "text"}]}`. |

### What the supervisor fixes itself

The server cannot set, override or see any of these:

- Labels: `org.slim-m.managed-by=slimm-supervisor`, `org.slim-m.instance=<the supervisor's instance id>` and `org.slim-m.connector=<id>`.
  The instance id is generated once and kept in the supervisor's state directory, so two deployments on one host never touch each other's connectors.
- Not privileged; all capabilities dropped and none added; `no-new-privileges`; the runtime's default seccomp and AppArmor or SELinux profiles, never `unconfined`.
- User `65532:65532`, whatever the image's `USER` says.
- Read-only root filesystem, a 64 MiB `noexec,nosuid` tmpfs at `/tmp`, and the image's own entrypoint and command, which the server cannot replace.
- No bind mounts, no devices, no sysctls, no published ports, private IPC, PID and UTS namespaces, and an init process.
- The only mount is the connector's own named volume at `/data`, made by the supervisor and owned by 65532.
  A one-shot container from the supervisor's own image, with only `CHOWN`, no network and only that volume mounted, sets the owner once at create.
- Network: a network of its own per connector, created `internal` in gateway mode `isolated`, so it has no route out and the host has no address on it (amendment below).
  Its only neighbour is the connector's gateway (below), and `HTTPS_PROXY`, `HTTP_PROXY` and `NO_PROXY` point at it.
- No restart policy: the server decides when to restart, so the crash count and the auto-disable live where the admin sees them.
- Log driver `json-file` with 10 MiB per file and 3 files, so a chatty connector cannot fill the disk.
- Global ceilings from the supervisor's own configuration: at most `SLIMM_SUPERVISOR_MAX_CONNECTORS` (default 8), and per connector at most `SLIMM_SUPERVISOR_MAX_MEMORY_MIB` (default 512), `SLIMM_SUPERVISOR_MAX_CPUS` (default 1.0) and `SLIMM_SUPERVISOR_MAX_PIDS` (default 256).

### The egress gateway

Docker and Podman networks cannot limit egress by hostname, so each connector gets a gateway container next to it.
The gateway is the supervisor's own image run as `slimm-supervisor gateway`, with the same hardening as a connector, attached to the connector's internal network and to the egress network the operator names (`SLIMM_SUPERVISOR_EGRESS_NETWORK`).
It is an HTTP forward proxy with `CONNECT`, and it forwards only to the server's API address and the approved `host:port` pairs.
It resolves names itself and checks the resolved address, the way the link-preview SSRF guard does (0019), so a hostname that resolves to a private address is refused unless `egress_private` is set.
Always refused, whatever is approved: loopback, link-local and metadata addresses, every docker bridge network, and `SLIMM_SUPERVISOR_LAN_DENY`.
The supervisor cannot see the docker host's own LAN addresses, so the operator lists them in `SLIMM_SUPERVISOR_LAN_DENY`, and `egress_private` is refused while that list is empty.
The server's API address is the one private address that is always allowed.
A connector that ignores the proxy variables reaches nothing, which is the point.
UDP and other non-TCP egress are not supported.

## What each side can do when it is compromised

| Who is compromised | Can | Cannot |
| --- | --- | --- |
| The server | Create, start, stop and remove connectors in the sandbox above; run any image under an allowed registry prefix in it; approve egress for those connectors; read their logs; use up the supervisor's ceilings. | Reach the runtime socket; mount a host path; start a privileged container or add a capability; touch a container or volume the supervisor did not label; publish a port; exceed a ceiling. |
| A connector | Use its bot token within the permissions the admin approved; reach the server's API and its approved hosts through its gateway; write its own volume. | See the runtime socket; reach the LAN unless approved; reach another connector; reach the host. |
| The supervisor | Everything the runtime's user can do, which is root on the host for a rootful runtime. | Be reached by anything but a peer with the server's uid and the secret. |

An allowed registry prefix is only as narrow as its owner: `ghcr.io/` alone would let a compromised server run any public image in the sandbox, which is why the default is the official organisation.
The data a compromised server could send out through a connector is data it already holds, so egress approvals protect against a malicious connector, not against the server.

## How it ships

- `slimm-supervisor` is a second small Rust binary in this repository, `crates/slimm-supervisor`, a member of the main workspace, built static with musl.
  It is not a subcommand of `slimm-server`, so the internet-facing binary never contains a runtime client, and the supervisor's dependency list stays short enough to review.
- Its image is `ghcr.io/slim-m-org/slim-m-supervisor`, distroless static, built and signed with the server's images and versioned with the server.
- The protocol is hand-written on both sides, as the wire contract is elsewhere, with request and response fixtures in `docs/connectors/supervisor-fixtures/` that a test on each side reads.
- The server side is a small client module behind the connectors feature; it is constructed only when `SLIMM_CONNECTOR_SUPERVISOR_SOCKET` is set.

### docker-compose

The supervisor is an overlay, `docker-compose.connectors.yml`, turned on like the voice overlay:

```text
COMPOSE_FILE=docker-compose.yml:docker-compose.connectors.yml
```

The overlay adds:

- a `supervisor` service: the hardened anchor (read-only root, `cap_drop: ALL`, `no-new-privileges`), `user: "0:65532"` so the socket's group is the server's, `network_mode: none`, the runtime socket from `SLIMM_RUNTIME_SOCKET` (default `/var/run/docker.sock`) mounted at `/run/runtime.sock`, a `slimm_supervisor_state` volume for the instance id, and the `slimm_supervisor_run` volume for its own socket;
- the `slimm_supervisor_run` volume on the `server` service, mounted at `/run/slimm-supervisor`, and `SLIMM_CONNECTOR_SUPERVISOR_SOCKET` and `SLIMM_SUPERVISOR_SECRET` in its environment;
- a `connectors_egress` network that the gateways join, with the server attached so connectors can reach its API.

The server never mounts the runtime socket, in this overlay or any other.

### Bare metal

`deploy/systemd/slimm-supervisor.service` runs the binary as a `slimm-supervisor` user with the runtime's group as a supplementary group, `RuntimeDirectory=slimm-supervisor`, `Group=` the server's group, `PrivateNetwork=yes`, `RestrictAddressFamilies=AF_UNIX`, `NoNewPrivileges=yes`, `ProtectSystem=strict`, `ProtectHome=yes` and an empty capability set.
The runtime's group is root-equivalent, which is exactly why only this small service is in it, and never the server.

### Operator setup

1. Generate a secret with `openssl rand -hex 32` and put it in `.env` as `SLIMM_SUPERVISOR_SECRET`.
2. Add `docker-compose.connectors.yml` to `COMPOSE_FILE`, and set `SLIMM_RUNTIME_SOCKET` if the runtime's socket is not `/var/run/docker.sock`.
3. Optionally widen `SLIMM_SUPERVISOR_REGISTRIES`, change the ceilings, or add `SLIMM_SUPERVISOR_LAN_DENY`.
4. Run `docker compose up -d`.
   The supervisor checks the runtime at start (below) and exits with the reason if it cannot enforce the sandbox.
5. The Dock now offers host-run connectors to admins; before this, a connector manifest that asks to be host-run says the server is not set up for it.

### A self-hoster who never enables it

Nothing changes.
The default compose file has no supervisor, no extra volume and no runtime socket anywhere.
The server builds no supervisor client, the Dock offers no host-run install, and admin-started connectors (the manifest card) work as before.

## Rootless Docker and Podman

- Only rootful Docker Engine 28.0.0 or newer is supported (amendment below); the supervisor refuses Podman and rootless Docker at start and names why.
- At start, and on `hello` until the runtime is ready, the supervisor checks that the runtime can enforce what it promises: the engine and its version, AppArmor or SELinux, cgroup v2 with the memory, cpu and pids controllers, a seccomp profile, and an isolated internal network it creates and removes as a probe.
  If any check fails it refuses to create connectors and says which, rather than running them without limits.
- Podman 5.8.1 and rootless Docker 29.10.0 were tried on the test VMs on 2026-11-23; `docs/connectors/operating.md` has what each lacked.

## Failure modes

- **Supervisor down or unreachable.** Running connectors keep running; the runtime owns them, not the supervisor.
  The server marks host-run connectors "runtime unavailable" to admins, refuses install, start and stop with that reason, and retries `hello` with backoff from 1 s to 30 s.
- **Runtime down.** The supervisor answers `runtime_unavailable`, and the server shows the same state.
- **After either comes back, and after a server restart or a host reboot,** the server reconciles: it compares the connectors it has enabled with `GET /v1/connectors`, creates what is missing and starts what should run, with the usual backoff.
  A labelled container the server has no record of is removed; its volume is kept and named in the server log.
- **A crashing connector.** The server sees `exited`, starts it again after 1 s, doubling to 5 minutes, and disables it after 5 crashes within 10 minutes, with the same admin alert and audit row the module breaker sends (0091).
- **A policy refusal.** A `policy` or `limit` answer is not retried; the admin sees the reason on the connector.
- **Version skew.** The supervisor refuses fields it does not know, so upgrade the supervisor before the server; a `hello` whose `protocol` is not the one the server speaks shows as the host's health reason.
- **Supervisor upgrade.** Connectors keep running; gateways are recreated from the new image on the next start of each connector.

## Logging and audit

- The supervisor logs one JSON line per request to stdout: verb, connector id, peer uid, outcome and error code.
  It never logs environment values or the bearer secret.
- The server writes an audit row for every admin action on a connector (install, approve egress, enable, disable, uninstall, keep or delete the volume), and for an automatic disable, with the system as the actor.
- Container logs stay in the runtime's rotated files; the server reads them on demand for admins and does not store them.

## Out of scope

- A supervisor on another host, over TCP, or Kubernetes.
- Building images, private registry credentials, and automatic image updates (an update is a new manifest digest, so remove and create).
- Published host ports and inbound traffic to a connector.
- UDP or other non-TCP egress, and connector-to-connector networking.
- GPUs and other devices.
- Docker Desktop on Windows and macOS, which may work and is not tested.
- The manifest, the scoped token and the host-rendered settings, which are the manifest card's.

## Open for the owner

Where the owner has not decided, this record takes the safer side:

1. **Registries.** The default allowlist is the official organisation, `ghcr.io/slim-m-org/`, and only the operator can widen it.
   The alternative is to allow any registry and rely on the consent screen's "unreviewed" label, as community modules do.
2. **LAN egress.** This follows the module precedent: an admin may grant a connector the Private network approval, and the operator's deny list always wins.
   The safer alternative is to make LAN egress operator-only.
3. **Published ports.** A connector cannot publish a host port, so a connector cannot host a game server itself.
   Allowing it would need its own consent line and a port range the operator sets.
4. **The three reads.** Health and logs need reads beyond the four verbs; they are limited to labelled containers and change nothing.
5. **Default ceilings.** 8 connectors, and per connector at most 512 MiB, 1 CPU and 256 processes, with 128 MiB, 0.5 CPU and 64 processes when the manifest asks for nothing.

## Amendment, 2026-11-23: the security review

A review of the built supervisor and server found the following, and each is now fixed and tested.

- An `internal` bridge network still gives the host the network's gateway address, so a connector could reach every host service listening on 0.0.0.0 through it; a real Docker probe showed it open.
- Connector networks now use gateway mode `isolated` (Docker 28.0.0), and the supervisor refuses a connector network that still has a gateway, at its startup probe, at create and at start.
- The supervisor now refuses Docker Engine older than 28.0.0, which also carries the embedded-resolver fix for CVE-2024-29018, and a probe test asserts that a lookup from a connector is never answered from outside.
- It refuses a runtime that applies neither AppArmor nor SELinux, since "never unconfined" was not checked; Docker on an SELinux host needs `"selinux-enabled": true`.
- It refuses Podman, which ignores gateway mode `isolated` and leaves the host reachable from an internal network, and rootless Docker, which applies no AppArmor or SELinux profile.
- The server believes `X-Forwarded-For` only from a peer in `SLIMM_TRUSTED_PROXIES`, and the connectors overlay pins the egress subnet and excludes it.
- The gateway removes forwarding headers and sends `Connection: close` on every request to the server, and reads the request inside a `CONNECT` tunnel to it, splicing an upgrade through only after the server's 101.
- A connector's data volume has a ceiling, `limits.volume_mib` (default 256 MiB, operator ceiling `SLIMM_SUPERVISOR_MAX_VOLUME_MIB`, default 1024), shown on the consent sheet.
- The supervisor measures every connector volume every 30 seconds and stops a connector past its ceiling; the server turns it off with the breaker's alert and audit row.
- The residual risk is the window between measurements: a connector can write past its ceiling for up to 30 seconds, bounded by the disk's write speed, because the local volume driver has no quota of its own.
- `egress_private` is refused while `SLIMM_SUPERVISOR_LAN_DENY` is empty, since the docker host's own LAN address is otherwise reachable and the supervisor cannot see it.
- The generic bot routes no longer accept a connector's principal, which is now marked for good (migration 0212), and a marked principal whose module row is gone holds nothing.
- The plain module uninstall deletes only WASM rows, so only the connector uninstall, which revokes the token in the same transaction, removes a connector.
- An egress host whose last label is digits or `0x` hex is refused, and an IPv6 literal that carries an IPv4 address is shown as that IPv4, so consent shows what is dialled.
- Every `supervisor/1` call names the server's deployment in `X-Slimm-Deployment`, and a supervisor binds to the first one it hears: run one supervisor per deployment.
- `hello` probes the runtime only until it is ready.
- A connector's token is held to a route table before any handler runs, because many routes check no permission bit; a disabled connector reaches only `GET /connectors/me`.
- Posted command output reaches `@everyone` only when both the member who ran it and the module's principal hold `mention_everyone`.
- Gateways and the volume helper run the supervisor's own image by its content id, and the bare-metal unit gains a system call filter.
- The supervisor image is built natively per architecture, merged by digest and cosign-signed with the server's images under the same tags, release-please bumps the supervisor crate with the server, and the compose overlay needs `SLIMM_VERSION` instead of following `latest`.

## Amendment, 2026-11-23: the pre-1.0 audit

- Uninstalling a host-run connector with its data deleted is refused with 503 while the supervisor cannot remove the container and its volume.
  The connector is turned off first, so the monitor does not create it again, and the monitor never runs a pass while an uninstall holds the gate.
  The orphan sweep still keeps volumes, so a delete-data request can no longer be turned into a kept volume by a failed removal.
- A connector turned off for crashes or a full volume is marked and disabled in one transaction, so a database error cannot leave a connector that says it was turned off while the module stays enabled.
- The server logs one warning when a request carries `X-Forwarded-For` from a peer outside `SLIMM_TRUSTED_PROXIES`, naming the peer, since the header is then ignored and every caller shares the proxy's rate-limit key.
- An update that makes a host-run connector admin-started removes its container, keeps its volume, and revokes the container's token: the admin is shown a new one once, as for any admin-started install.
- The runtime cannot report one volume's size: `/system/df` ignores filters and `/volumes/{name}` carries no usage, so every volume on the host is read, at most every 30 seconds, with a 20 second limit.
- A start measures before it takes the supervisor's verb lock, so a slow report never holds other verbs back.
- A check that cannot read the sizes logs why; after three in a row the supervisor stops every running connector that has a volume, since its ceiling can no longer be enforced.

