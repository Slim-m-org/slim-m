# 0019 - Link unfurling, and the SSRF defense it demands

Date: 2026-09-04
Status: accepted

The owner accepted all three open questions as recommended: unfurl server-side, proxy the preview image through the server, and gate it behind an operator toggle (default off, opt-in).

## Context

The owner asked for link preview cards in the transcript: a pasted URL should show a title, description, and image, the way Discord and Slack unfurl links.
Today a bare URL renders as clickable text only (`message_inline.dart`'s recursive-descent parser produces an `InlineLink`; `message_text.dart` opens it with `launchUrl`).
That linkifier is sound - it trims trailing sentence punctuation and balances brackets - and link opening works on the desktop build (verified through `gio open`, the exact GIO call `url_launcher_linux` makes).
So the only missing piece is the preview, and a preview means the server fetches an arbitrary, user-supplied URL to read its metadata.

Fetching a user-supplied URL server-side is the textbook Server-Side Request Forgery (SSRF) surface.
OWASP now files SSRF under A01:2025 Broken Access Control.
The danger is not hypothetical: a pasted `http://169.254.169.254/latest/meta-data/` turns our server into a reader of its own cloud metadata; a pasted `http://192.168.1.1/` turns it into a probe of the operator's internal network.
This deployment already fetches external content on a member's behalf for privacy reasons (the GIF proxy in `crates/slimm-server/src/http/gifs.rs`, so a member's IP and search terms never reach Tenor or Klipy), so the architecture is a natural extension of an existing, accepted pattern - but the GIF proxy only ever talks to two known, configured provider hosts, whereas unfurling talks to whatever a member pastes.

## The threat model

An attacker is any member who can post a message (unfurl is triggered by an ordinary paste), so treat the fetcher as attacker-controlled input with no trusted floor.

Two Rust-specific bypass classes are documented in real 2025 advisories and must be defended explicitly, because the naive "resolve the host and check the IP" guard falls to both:

1. Multi-address DNS fall-through (stoat/January, GHSA-4mcc-p83c-r77q).
   The guard resolved the hostname and validated only the *first* returned address, then let `reqwest` re-resolve and dial.
   `reqwest` tries every resolved address in order, so a hostname with two A records - one unreachable public IP, then a loopback IP - passed the check on the public address and fell through to loopback when the public one failed to connect.
   The lesson: validation must run on the exact addresses the connector dials, and every one of them, not the first.

2. Numeric-literal resolver skip (vaultwarden, GHSA-72vh-x5jq-m82g).
   When the URL host is a numeric IP literal, the `url` crate parses it directly and `reqwest` connects without ever calling the custom DNS resolver, so a resolver-based guard never runs.
   Worse, `IpAddr::from_str` only recognizes dotted-decimal, so a pre-connect string filter misses the other encodings the WHATWG URL parser accepts: `2130706433`, `0x7f000001`, and `0177.0.0.1` all reach `127.0.0.1`.
   The lesson: a resolver hook alone is insufficient; the host must also be validated as a literal, using the URL crate's own normalized parse rather than a hand-rolled `from_str`.

Redirects compound both: a public URL can 302 to an internal one, or to a numeric literal that skips the resolver, so each hop is a fresh instance of the whole problem.

## Decision: fetch behind a guard that validates every dialed address and every hop

Deny-list, not allow-list.
OWASP prefers an allow-list, but the feature's whole point is to unfurl arbitrary public URLs, so an allow-list of hosts is not a valid solution here; the deny-list below is the accepted last resort, applied at the layer that actually dials.

The fetcher (a new `http/link_preview/` module beside `gifs/`) enforces, in order:

1. Scheme allow-list: `http` and `https` only, rejected before anything else.

2. Literal-host pre-validation.
   Parse with the `url` crate and inspect `Url::host()`.
   If it is `Host::Ipv4` or `Host::Ipv6`, run it through `is_blocked` (below) directly - this is what catches the decimal/hex/octal encodings, because the WHATWG parser has already normalized them to a real `Ipv4Addr`.

3. A guarding DNS resolver installed on the `reqwest` client (`ClientBuilder::dns_resolver`).
   It resolves the name (`tokio::net::lookup_host`, the system resolver, no new dependency), collects *all* addresses, and rejects the whole request if *any* resolved address `is_blocked` - failing closed rather than filtering, so a mixed public+internal record set cannot rebind through the fall-through path.
   Because this is the same resolver the connector dials through, the address it validates is the address it connects to; there is no second resolution to disagree with it.

4. Manual redirect handling: `reqwest` redirects disabled (`redirect::Policy::none()`), each `3xx` `Location` re-run through steps 1-3 from the top, capped at 5 hops.
   Manual handling is what re-applies the literal-host check on every hop, which the resolver alone would skip for a literal redirect target.

5. Bounds on everything: a connect timeout and a total timeout (5s), a hard response-size cap read by streaming and stopping (256 KB is plenty - `og:` and `<title>` live in `<head>`), and a rejection of any non-2xx status.

6. Content-type gate: the page fetch accepts only `text/html` / `application/xhtml+xml`; the image fetch (below) accepts only `image/*` and re-caps size.
   Always confirm the response shape before parsing it, per OWASP.

`is_blocked(IpAddr)` blocks, from the IANA special-purpose registries and the OWASP minimum:
IPv4 `0.0.0.0/8`, `10.0.0.0/8`, `100.64.0.0/10`, `127.0.0.0/8`, `169.254.0.0/16`, `172.16.0.0/12`, `192.0.0.0/24`, `192.0.2.0/24`, `192.88.99.0/24`, `192.168.0.0/16`, `198.18.0.0/15`, `198.51.100.0/24`, `203.0.113.0/24`, `224.0.0.0/4`, `240.0.0.0/4`;
IPv6 `::/128`, `::1/128`, `fc00::/7`, `fe80::/10`, `fec0::/10`, `ff00::/8`, `2001::/32` (Teredo), `2001:db8::/32`, `64:ff9b:1::/48`, `100::/64`, and the mapped/translated forms `::ffff:0:0/96`, `64:ff9b::/96`, `2002::/16` unpacked to their embedded IPv4 and re-checked (an IPv4-mapped or 6to4 address is just a v4 address wearing a v6 hat).
Implemented as explicit range checks rather than the unstable `IpAddr::is_global`, and covered by unit tests that assert each documented bypass payload is rejected.

## OpenGraph extraction

Read only the first bounded slice of the body and extract `og:title`, `og:description`, `og:image`, `og:site_name`, falling back to `<title>` and `<meta name="description">`, then to `twitter:*`.
Resolve a relative `og:image` against the final (post-redirect) URL, and run that image URL back through the same SSRF guard before fetching it - the image host is as attacker-controlled as the page host.
Bound title and description lengths before storing.

Open sub-decision: a full HTML parser (`scraper`/`html5ever`) is more robust than a bounded byte-scan for `<meta>` tags but adds a sizable dependency tree.
Recommendation: start with a focused, bounded extractor over the head slice (no new dependency), since OG tags are a flat, simple shape; revisit `scraper` only if real pages defeat it.

## Storage, wiring, and the client

Follow the attachment precedent, not a column on `Message`: a preview is per-message side data, enriched onto the message on read, never a field every message `SELECT` has to carry (see the `per-message-data-goes-in-a-side-table` reasoning the attachments layer already embodies).
Cache previews by normalized URL with a TTL, so the same link pasted twice is fetched once, and so a restart does not re-fetch a channel's history.
Proxy the preview image through the server exactly as `select`ed GIFs are stored/served, so a viewer's IP never reaches the third-party host on render.
Gate the fetch behind the existing rate limiter (a new `Class`) so unfurling cannot be used to make the server hammer a target.
The client fetches previews for the URLs in a message and renders a card, honoring the existing auto-download and preview-quality settings the media pipeline already exposes; a failed or missing preview simply renders nothing extra, never an error surface.

## What this is not

No JavaScript execution and no headless browser: a plain HTTP GET of the HTML head only.
No unfurling of non-http(s) schemes, and no following of redirects into blocked space.
No content scanning or storage of page bodies beyond the extracted metadata and the one proxied image.

## Open questions for the owner

- Confirm server-side unfurl at all, versus leaving links as plain clickable text (the status quo).
- Confirm proxying the preview image through the server (privacy, matches GIFs, more work and storage) versus text-only cards with no image.
- Whether unfurl should be an operator toggle (like GIF search is `SLIMM_GIF_PROVIDER`-gated) or always on.
