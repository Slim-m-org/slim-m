<!-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0 -->
# Capacity guidance

How the first-run admin setup and Server metrics turn a machine's cores, memory and disk into "comfortable for about N people".
The server computes it in `crates/slimm-server/src/capacity.rs`, and `GET /space/setup` returns it to an admin.

It is a range, not a promise.
Every input is a measurement from `perf/load/FINDINGS.md` or `docs/sizing.md`, and the unit tests in `capacity/tests.rs` pin the formula to those figures.

## What the server reads

- Cores: the process's own parallelism, which honours a container CPU quota.
- Memory: the smaller of the host's RAM and the cgroup limit the memory guard already resolves (`SLIMM_MEMORY_LIMIT_BYTES` overrides it).
- Disk: free space on the volume holding the uploads directory.

## The formula

The connection limit is the smallest of four ceilings.

| Ceiling | Figure | Source |
| --- | --- | --- |
| Hub cap | 1024 connections | `hub::MAX_CONNECTIONS` |
| Memory | (memory - 64 MiB guard reserve - 11 MB floor) / 211 KB per connection | docs/sizing.md, Memory |
| Fan-out | sqrt(87,000 deliveries/s per core x cores x 0.5 / 0.1 messages/s per connection) | FINDINGS, fanout: 252k deliveries/s at 2.9 cores |
| Requests | last good `http_mix` step (2000, 2500, 3000 at 2, 4, 8 cores; flat above, linear below 2) / 0.1 requests/s per person | FINDINGS, http_mix |

The people range is then taken from that limit:

- High end: 75% of it, one device per person.
- Low end: 50% of it, 1.5 devices per person.

Both are rounded to ten.

## Assumptions, and why they lean pessimistic

- Everyone watches one busy channel, the worst case for fan-out.
- The fan-out figure predates the read-buffer and SQLite fixes, which made a delivery several times cheaper, so the processor ceiling is conservative.
- One request every ten seconds and one message every ten seconds per connection are plausible chat rates, not measured ones.
- Below two cores the quota throttles the process into second-scale delays (docs/sizing.md), which this model only approximates by scaling the ceilings down.
- Past about four cores nothing here grows: the 1024 connection cap binds first, so more hardware will not raise the range.

## Voice

Voice runs through LiveKit, which may be on another machine, so the server cannot say what it will carry.
When voice is configured the report also gives a range for people in one call if LiveKit shares this machine.
It subtracts the server's own memory need, then applies 13 MB plus 4.7 MB per participant and calls 35% to 55% of that comfortable, because sixty people were comfortable on 512 MB and a hundred hit the cap (docs/sizing.md, Voice).
Otherwise the screen says it depends on that machine's memory, about 60 people per 512 MB.
Video is limited by uplink bandwidth, not by anything here.

## Recommendations

The client suggests, next to the setting it concerns:

- Free disk under 20 GB, or under 10% of the volume: photo compression and a retention window.
- Two cores or fewer: a lower screen share limit.
