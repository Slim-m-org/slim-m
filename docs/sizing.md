<!-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0 -->
# Deployment sizing

How much processor and memory a slim-m server needs, measured rather than estimated.

Everything here comes from a capacity study run on 2026-09-15 against server 0.63.0.
The harness is `scripts/loadtest.py`, which holds real sessions open over real websockets and reads the server's own `/metrics` across each run.
Runs were constrained with systemd resource limits, which is how Docker expresses the same caps, so the numbers transfer to a container deployment.

## The short answer

There are two containers to size and they run out of different things.

| Container | Give it | Carries | Bound by |
| --- | --- | --- | --- |
| slim-m server | 2 cores, 512 MB | up to 1024 connected people, the hard cap | processor |
| LiveKit, voice | 2 cores, 512 MB | about 60 people in one call | memory |
| LiveKit, video | 2 cores, 512 MB | 1.3 Mbps per subscriber | your uplink |

Three different resources run out first, so the dial to turn is a different one each time.
Video in particular is not limited by the machine at all in any deployment small enough to be reading this page.

One core for the server is the single most important finding here, and it is not a matter of degree.
At one core the server is throttled into second-scale delays while using only three quarters of the core it was given.
Two cores is the first setting that behaves at all, rather than a capacity figure.

For voice, the processor is never the constraint and raising it buys nothing.
Memory is what decides how many people fit in a call.

## Hard limits

| Limit | Value | How it fails |
| --- | --- | --- |
| Simultaneous websocket connections | 1024 | Refused cleanly. Existing connections are unaffected. |
| Memory per connection | 211 KB | Re-measured 2026-09-17 on 0.65.0; the 2026-09-15 study said 144 KB. See Memory. |
| Memory at the connection limit | about 222 MB | Connections cannot push the server past this, because the count cap stops them first. |
| Delivery throughput | about 26,000 per second | Latency degrades before the processor saturates. |

A "delivery" is one message arriving at one connection.
One message sent into a channel a hundred people are watching is a hundred deliveries.
Deliveries, not messages, are the unit that decides how much processor a deployment needs.

## Processor

Measured at a constant offered load of roughly 26,000 deliveries per second, varying only the quota.
These runs used a native build under systemd limits, not the musl image, and until 2026-10-07 the image's allocator cost it about three times the processor per delivery; since the server switched to jemalloc the image costs what a native build does, so the table now holds for it (docs/dependencies.md, tikv-jemallocator).

| Quota | Cores actually used | Median delivery | Verdict |
| --- | --- | --- | --- |
| 1 core | 0.75 | 1,305 ms | Unusable |
| 1.5 cores | 0.85 | 541 ms | Poor |
| 2 cores | 0.95 | 44 ms | Good |
| 4 cores | 1.30 | 21 ms | Better |
| 8 cores | 1.48 | 12 ms | Marginal gain |

Two things in that table are worth understanding before choosing a number.

The server never uses more than about 1.5 cores no matter how many it is offered.
Going from four cores to eight changed throughput by 0.2 percent while halving the median delay, so past two cores you are buying responsiveness rather than capacity.

At one core it used only three quarters of what it had while delivering a 1.3 second median.
It was not short of work to do, it was being stopped: a quota is enforced by freezing the process for part of every scheduling window, so a tight quota collapses latency while average utilisation still looks comfortable.
That is why one core is a cliff rather than a slope, and why the first table row says unusable rather than slow.

## Memory

Memory is predictable, and it costs more per connection than this page first reported.

The floor is about 11 MB, each connection adds about 211 KB, and the connection cap means the total can never exceed roughly 222 MB from connection load.

**That per-connection figure is a correction.** The original study measured 144 KB against server 0.63.0. A re-measurement on 2026-09-17 against 0.65.0, on a freshly started process holding 1000 sockets with no other work in flight, found 206 MiB of resident growth - 211 KB each, about 1.47 times the earlier number.

Which of the two conditions explains the gap is not established. The re-measurement isolated the process deliberately (fresh start, accounts already registered, so no Argon2 arenas inflating the total) and is the more careful of the two, but it also ran on a later server, so real growth between versions and a difference in method are both live explanations.

**The provisioning advice below does not change**, which is why this is a corrected figure rather than a corrected recommendation: 222 MB still fits inside the 256 MB the table already suggests at the connection cap. Anyone sizing at the cap was already being told the right number, for a slightly wrong reason.

A server given less than it needs is **killed by the kernel rather than degraded**.
Holding connections at the cap, a 160 MB ceiling survived and a 144 MB ceiling was killed within a second, having accepted several hundred connections it could not afford.
The memory admission guard added after this study refuses new connections when headroom runs short, but the reserve it keeps is part of what a deployment must budget for.

| Connections | Recommended memory |
| --- | --- |
| 100 | 96 MB |
| 250 | 128 MB |
| 500 | 160 MB |
| 1024 | 256 MB |

Those figures include the 64 MB the admission guard holds back.

## How many people that supports

Two cores sustains about 26,000 deliveries a second.
Spending that budget on a space of a given size gives the message rate it can carry.

| People in the space | Messages a second it sustains | Which is, per person |
| --- | --- | --- |
| 50 | 520 | 624 a minute |
| 100 | 260 | 156 a minute |
| 250 | 104 | 25 a minute |
| 500 | 52 | 6 a minute |
| 1024 | 25 | 1.5 a minute |

The last row is the one worth reading twice.
At the connection limit, the sustained budget is about one and a half messages per person per minute, which is a plausible real chat rate rather than a comfortable margin.
So the 1024-connection cap and the processor capacity run out at roughly the same population, which means the cap sits in about the right place rather than being arbitrary.

Assumptions behind those numbers, all of which make them pessimistic:

- One connection per person. Somebody with a phone and a laptop counts twice.
- Everyone watching the same busy channel, which is the worst case for fan-out.
- Sustained activity, not a peak. Real deployments are idle almost all of the time.

Splitting people across channels helps considerably but not completely.
Measured at the same message rate, sending into a channel only the sender could see cost 2.6 percent of a core where a public channel cost 9.4 percent.
That is roughly a fourfold difference per connection, and the reason it is not larger is that the hub broadcasts every event to every connection, each of which evaluates whether it may see it.
A connection that cannot see a channel still pays to work that out.

## Reconnect storms

Every client reconnecting at once is how services usually fall over, and it is not a hypothetical here: `main` is continuously deployed, so a Watchtower restart drops every connected person simultaneously and they all come back together.

Measured 2026-09-17 with `scripts/reconnect-storm.py`, which aborts each socket at the transport rather than closing it politely - a restart does not say goodbye, and the server's cleanup path differs between the two.

**At a realistic shape it is a non-event.** 120 sockets, forty people with three devices each, dropped and returning together:

| Round | Returned | Whole herd back in | Median | p95 | Slowest |
| --- | --- | --- | --- | --- | --- |
| first connect | 120/120 | 0.17s | 78 ms | 88 ms | 160 ms |
| after drop 1 | 120/120 | 0.09s | 65 ms | 69 ms | 88 ms |
| after drop 2 | 120/120 | 0.08s | 66 ms | 69 ms | 84 ms |
| after drop 3 | 120/120 | 0.09s | 69 ms | 70 ms | 91 ms |

Nobody is refused, the whole group is back inside a tenth of a second, and the server spends 0.33 seconds of processor time doing it - about three percent of one core. Reconnects get slightly *faster* after the first round rather than degrading.

So the cost of a deploy, to someone with the app open, is about seventy milliseconds.

**What paces a larger storm is the ticket bucket, not the server.**

A connect ticket is single-use, so everyone returning has to mint one, and that route is rate limited per account: ten in a burst, then one a second. Pushed to 1000 sockets, every one still came back, but the timings change completely:

| Sockets | Returned | Whole herd back in | Median | Slowest | Tickets refused |
| --- | --- | --- | --- | --- | --- |
| 1000 | 1000/1000 | 18-27s | 3.2-10.2s | 26.4s | 5,312 of 7,312 asked |

The server was bored throughout - 1.98 seconds of processor time, four percent of one core. It refused seven ticket requests in ten, each client backed off and asked again, and an operation that takes 70 ms unimpeded took up to 26 seconds.

**Read that as a property of the harness before reading it as a finding.** Those 1000 sockets sit on forty accounts, twenty-five each, because that is how the harness reaches a high connection count without paying for a thousand registrations. Nobody has twenty-five devices. A real storm of a thousand people is a thousand accounts asking for one ticket each, which is inside the per-account burst and looks like the 120-socket table above.

What it does establish is where the ceiling is when a storm does hit the limiter: the limiter absorbs it, everyone eventually returns, nothing is dropped, and the cost is latency rather than failure. That is the right failure mode. It also means a single account holding many sockets - a bot, or a test harness - is throttled rather than able to stampede the server, which is the behaviour the per-account bucket exists for.

Not measured: a storm of a thousand *distinct* accounts, which needs a thousand registrations and would say whether per-user state changes the per-connection memory above.

## Voice

Voice runs entirely through LiveKit, a separate container with its own limits, so nothing above applies to it.
It is bound by memory where chat is bound by processor, which is why the two need separate rows rather than one combined table.

Measured against LiveKit capped at two cores and 512 MB, the deployment's own configuration.

| People in one call | Processor | Memory | Subscriptions |
| --- | --- | --- | --- |
| 5 | 1.8% of a core | 36 MB | 25 |
| 10 | 3.2% | 59 MB | 100 |
| 20 | 5.7% | 105 MB | 400 |
| 40 | 10.5% | 204 MB | 1,600 |
| 60 | 13.8% | 295 MB | 3,600 |
| 100 | 23.8% | **511.8 MB, at the cap** | 600 of 10,000 delivered |

About 4.7 MB per participant on a 13 MB floor.
Processor is nowhere near binding: sixty people in a call used under a seventh of one core, and the two cores LiveKit is given are far more than it needs.

**How it fails is worth knowing.**
At a hundred people the container sat exactly on its memory ceiling and delivered six percent of the subscriptions: each participant received audio from six of the other ninety-nine.
Packet loss on what did connect was zero.
So it does not degrade audio quality, it silently stops subscribing people to each other, and a participant experiences it as joining a call and hearing almost nobody, with nothing reporting an error.

On 512 MB, treat sixty as comfortable and a hundred as past the edge.
Raising LiveKit's memory limit is the dial for larger calls, not its processor.

Subscriptions grow with the square of the room but processor does not follow.
Going from five to sixty people multiplied subscriptions by 144 and processor by only 7.5, because LiveKit forwards audio packets rather than mixing them.
That is good news for call sizes and the reason memory binds first.

### The media port range is not a participant limit

The shipped compose publishes 101 UDP media ports, commented as deliberately sized for a friend group, which invites the worry that it caps a call at about a hundred people.
It does not.

Measured by giving LiveKit a range of eleven ports and putting thirty participants in one call: it opened all eleven, held at eleven for the whole call, and nothing failed.
LiveKit binds the configured range up front and spreads connections across it rather than taking a port per participant.

So the range is a pool, not a ceiling, and the default is ample.
A deployment would have to be running many simultaneous calls before widening it came up, and memory would bind first.

## Video and screen share

Video is the case worth understanding before anyone plans a large call, because the constraint is not the one the rest of this page is about.

Measured against LiveKit at two cores and 512 MB, one publisher at the tester's high resolution:

| Publishers | Subscribers | Processor | Memory |
| --- | --- | --- | --- |
| 1 | 5 | 1.3% of a core | 37 MB |
| 1 | 15 | 2.4% | 63 MB |
| 1 | 30 | 4.2% | 110 MB |
| 2 | 20 | 4.5% | 94 MB |
| 5 | 20 | 7.3% | 138 MB |

Processor barely moves, and that is not a surprise once stated plainly: LiveKit forwards packets, it does not transcode them.
A video packet costs about what an audio packet costs to relay.
It is simply a much larger number of much larger packets.

**Bandwidth is the constraint, and it is the only figure here that is not about the machine.**
One camera stream cost **1.3 Mbps per subscriber**, measured at 26.2 Mbps total for one publisher and twenty subscribers, with zero packet loss.

That number scales the way the fan-out does, so it is worth doing the arithmetic before promising a feature:

| Shape | Streams relayed | Egress |
| --- | --- | --- |
| One person presenting to 20 | 20 | 26 Mbps |
| One person presenting to 50 | 50 | 65 Mbps |
| 10 people all on camera | 90 | 117 Mbps |
| 20 people all on camera | 380 | 494 Mbps |

A gigabit uplink carries roughly 770 subscriber-streams.
A typical home upload carries a handful, which is the real reason a self-hosted deployment should think about screen share before enabling it rather than after.

Everyone on camera is the shape that gets expensive, because it is quadratic in the same way chat fan-out is.
One person presenting stays affordable well past any call size the memory limit allows.

## Compose presets

Set these under the server service in `docker-compose.yml`.

A friend group, up to about fifty people:

```yaml
deploy:
  resources:
    limits:
      cpus: '2.0'
      memory: 256M
    reservations:
      memory: 64M
```

A community up to the connection limit:

```yaml
deploy:
  resources:
    limits:
      cpus: '2.0'
      memory: 512M
    reservations:
      memory: 128M
```

Two cores appears in both because it is the first quota that behaves, not because the smaller deployment needs the capacity.
Memory is the dial worth turning with size.
Raising the processor limit above two buys lower latency and no extra capacity.

## What is measured and what is not

Measured directly: the connection limit, memory per connection, the memory ceiling where it is killed, latency against processor quota from a quarter core to eight, delivery throughput, the difference visibility makes, and reconnect storms.

The 2026-09-15 study re-measured its own results in a second pass and reproduced all of them. A third pass on 2026-09-17, against a later server, did **not** reproduce one: memory per connection came out at 211 KB rather than 144 KB. That figure has been corrected above and the reason is left open, because two things changed between the passes and this page cannot say which mattered. Treat any single number here as good to roughly the version it was taken on.

Two identical runs differed by 23 percent at the median and 43 percent at the tail.
Every difference reported here is far larger than that.
Differences smaller than it are not reported as findings.

Not measured, and not covered by any number above:

- Sustained video. The video figures are half-minute runs, so a slow leak under an hour-long screen share would not have appeared.
- Bandwidth as the server experiences it. The 1.3 Mbps per subscriber was measured between processes on one machine, where the network is not a real constraint; a deployment's own uplink is what decides whether that arithmetic holds.
- Sustained multi-hour runs, so slow leaks would not have appeared.
- Attachment uploads, which have their own limit class and their own disk path.
- Anything above 1024 connections, which the server refuses.

## Reproducing this

```bash
cargo build --release --bin slimm-server

# Fan-out under steady load.
scripts/loadtest.py --base-url http://127.0.0.1:8080 --users 100 --per-account 3 \
  --senders 25 --messages 10 --workers 8

# Everyone dropped and returning at once, the shape a deploy produces.
scripts/reconnect-storm.py --base-url http://127.0.0.1:8080 --users 40 \
  --per-account 3 --rounds 3
```

For the memory figure specifically, start the server fresh and reuse cached accounts, so no registration pass leaves Argon2 arenas in the total: the first run of `reconnect-storm.py` against a new database registers accounts and inflates resident memory by tens of megabytes that have nothing to do with connections.

Watch the server's own processor time in the output before believing a latency number.
When the two disagree, the harness is the one that is wrong, and during this study it was wrong four times.
