# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""One virtual user's socket half: connect, hello, then time what arrives.

Delivery latency is measured from the moment the sender's REST call returned
to the moment this subscriber saw the resulting frame. Both clocks belong to
the same process, so the subtraction is honest without a synchronised clock,
and it measures the thing a person actually waits for rather than the
server's own internal view of when it published.

A ticket is single-use and short-lived, so it is minted immediately before
the connection rather than in a setup pass: a batch minted up front would
start expiring while the later connections were still opening.
"""
import asyncio
import json
import secrets
import time
import urllib.error

import websockets

HELLO_TIMEOUT = 10.0
PROTOCOL = 1
TICKET_ATTEMPTS = 12


class Subscriber:
    """One connected virtual user, recording arrival times into `seen`."""

    def __init__(self, name, api, ws_url):
        self.name = name
        self.api = api
        self.ws_url = ws_url
        self.ws = None
        self.connected = False
        self.failure = None
        self.frames = 0
        self.resync = 0

    async def _ticket(self):
        """A connect ticket, waiting out the per-account burst limit.

        Tickets allow ten in a burst and then one a second, per account. Any
        run asking one account for more than ten sockets hits that, and
        without this it looks exactly like the server refusing connections:
        a sweep for the connection ceiling stopped at a clean ten per account
        and reported a ceiling that was really this bucket.
        """
        delay = 1.0
        for attempt in range(TICKET_ATTEMPTS):
            try:
                got = await asyncio.to_thread(
                    self.api.call, "POST", "/auth/ws-ticket", {})
                return got["ticket"]
            except urllib.error.HTTPError as exc:
                if exc.code != 429 or attempt == TICKET_ATTEMPTS - 1:
                    raise
                await asyncio.sleep(delay + secrets.randbelow(500) / 1000.0)
                delay = min(delay * 1.6, 8.0)
        raise RuntimeError("unreachable")

    async def open(self):
        """Connects and completes the hello handshake.

        Returns True once the server has acked. A failure is recorded rather
        than raised so one bad connection does not abort a hundred-user run.
        """
        try:
            ticket = await self._ticket()
            self.ws = await websockets.connect(
                self.ws_url, open_timeout=HELLO_TIMEOUT,
                max_size=None, ping_interval=20)
            await self.ws.send(json.dumps(
                {"type": "hello", "ticket": ticket, "protocol": PROTOCOL}))
            raw = await asyncio.wait_for(self.ws.recv(), HELLO_TIMEOUT)
            frame = json.loads(raw)
            if frame.get("type") != "hello":
                self.failure = f"expected hello, got {frame.get('type')!r}"
                return False
            self.connected = True
            return True
        except Exception as exc:  # noqa: BLE001 - recorded, not swallowed
            self.failure = f"{type(exc).__name__}: {exc}"
            return False

    async def listen(self, seen, stop):
        """Records the arrival time of every `message.created` until `stop`.

        `seen` is shared across subscribers: `seen[message_id]` collects one
        arrival timestamp per subscriber, which is what lets the report say
        how many of the hundred actually received a given message and how
        long the slowest one took.
        """
        while not stop.is_set():
            try:
                raw = await asyncio.wait_for(self.ws.recv(), 1.0)
            except asyncio.TimeoutError:
                continue
            except Exception as exc:  # noqa: BLE001 - ends this subscriber
                if not stop.is_set():
                    self.failure = f"{type(exc).__name__}: {exc}"
                return
            self.frames += 1
            frame = json.loads(raw)
            kind = frame.get("type")
            if kind == "resync":
                self.resync += 1
                return
            if kind != "message.created":
                continue
            message = frame.get("message") or {}
            message_id = message.get("id")
            if message_id is not None:
                seen.setdefault(message_id, []).append(time.monotonic())

    async def close(self):
        """Closes whatever socket was opened, including a failed handshake's."""
        if self.ws is not None:
            try:
                await self.ws.close()
            except Exception:  # noqa: BLE001 - teardown is best effort
                pass


async def connect_all(subscribers, concurrency=25):
    """Opens every subscriber, bounded so the ticket route is not flooded.

    Tickets are rate limited per user, so a hundred users minting one each is
    within budget, but opening a hundred sockets in one instant is a
    thundering herd the harness would be measuring instead of the server.
    """
    gate = asyncio.Semaphore(concurrency)

    async def one(sub):
        async with gate:
            return await sub.open()

    return await asyncio.gather(*(one(s) for s in subscribers))
