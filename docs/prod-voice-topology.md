<!-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0 -->
# Prod voice topology

How call media actually reaches the live deployment, as read from its running configuration on 2026-11-02.
[OPERATING.md](OPERATING.md#ports-and-voice-off-the-lan) and [deploy/README.md](../deploy/README.md) describe the shipped compose files, and they are accurate for those files.
The live deployment differs from them in the ways below, so read this before reasoning about a prod call.
The source of these facts is [the voice and stream audit](research/voice-stream-audit-2026-11-02.md), items N4 and N5.

## The media path

- UDP 50000-50200 carries call media, published straight through to the LiveKit container.
  The shipped overlay publishes 50000-50100, so prod is 100 ports wider.
  Ten people need far fewer than 100, and the width is drift, not a requirement.
- TCP 7881 is the ICE-TCP fallback for a client that cannot send UDP.
- TURN over TLS answers on `turn.npc-server.top` at 443 and 5349, terminated by Traefik in front of LiveKit.
  LiveKit advertises it only as `turns:turn.npc-server.top:443?transport=tcp`, so the 443 route is the one clients use; Traefik sends that name to LiveKit by SNI and every other name on 443 to the HTTP routers.
  Its relay ports are 50101-50200/udp, inside the block the router forwards, just above the media range.
  There is no TURN over UDP on 3478, which the shipped overlay enables.
  A relay-only browser join from the LAN connected in about 1.4 s on 2026-11-03 with a relay candidate over TLS.
- `rtc.use_external_ip` is on, so LiveKit advertises the public address although the container sits behind NAT.
- `LIVEKIT_TURN_UDP_PORT=3479` is still defined in the prod `.env` and nothing reads it.
- All 14 sessions in the 24 hours before the audit used a direct `udp4` host pair.
  None used a relay or TCP.

## The LAN direct route

Native clients on the home network reach the API through `SLIMM_DIRECT_ADDRESSES=10.0.0.100:443` instead of going out through Cloudflare, which is about 116 MB/s on the LAN against 7.8 MB/s through the proxy.
This is for the HTTP API only, and the web client and video uploads still go through the public hostname.
Call media from a LAN client still goes to the public address and comes back through the router (hairpin).
UDP hairpin works: a LAN client selected a `udp4` host pair against the public address on 2026-11-01.
Its round trip time and loss are not measured yet.

## LiveKit settings in effect

The live image is `livekit/livekit-server` v1.10.1.
Prod sets none of the estimator keys, so the v1.10.1 defaults apply:

| Setting | In effect |
| --- | --- |
| `rtc.congestion_control.enabled` | true |
| `rtc.congestion_control.allow_pause` | false, so a weak subscriber is never paused |
| `rtc.use_send_side_bwe` | false, so the downstream estimator is REMB |
| `rtc.packet_buffer_size_video` | 500 |
| `rtc.packet_buffer_size_audio` | 200 |

The sample config in the LiveKit repo shows `allow_pause: true`, so a copy from it would change behaviour.
Write the defaults out explicitly rather than copying it.
Turn on `use_send_side_bwe` or a larger video buffer only after a viewer-side symptom has been measured, and A/B it in staging first.

## What is not known

- The home uplink has never been measured, and it is the real ceiling for screen share fan-out.
- A relay-only join to prod has never been run.
  It needs a private test channel and a debug build with the ICE transport policy set to relay.
- TURN on 443 has never been tried.

Each of these is a card on the Planka board.
