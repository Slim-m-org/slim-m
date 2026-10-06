# Changelog

## [0.82.0](https://github.com/Slim-m-org/slim-m/compare/server-v0.81.1...server-v0.82.0) (2026-10-06)


### Bug Fixes

* a moderation history that loads, webhook embeds with iso timestamps, and a desktop window that follows resizing ([#2000](https://github.com/Slim-m-org/slim-m/issues/2000)) ([aecafd0](https://github.com/Slim-m-org/slim-m/commit/aecafd027b186f58d28755430830591ad68d7eb5))
* answering a CallKit ring on a cold launch joins the call and ends the system call when it is over ([#2004](https://github.com/Slim-m-org/slim-m/issues/2004)) ([ff0870b](https://github.com/Slim-m-org/slim-m/commit/ff0870bddc6b14d76acd8c439cda15bed80cd59b))
* batch 3 of the october audit, server, canvas, accessibility, startup, update and notification fixes ([#2005](https://github.com/Slim-m-org/slim-m/issues/2005)) ([ffc76a2](https://github.com/Slim-m-org/slim-m/commit/ffc76a2fcdbf2656db87684ba64a8b31dc7072f9))

## [0.81.1](https://github.com/Slim-m-org/slim-m/compare/server-v0.81.0...server-v0.81.1) (2026-10-02)


### Miscellaneous Chores

* **server:** Synchronize server versions

## [0.81.0](https://github.com/Slim-m-org/slim-m/compare/server-v0.80.0...server-v0.81.0) (2026-10-02)


### Bug Fixes

* **server:** a typer who leaves mid-typing no longer leaves the indicator stuck ([#1599](https://github.com/Slim-m-org/slim-m/issues/1599)) ([6cde8b6](https://github.com/Slim-m-org/slim-m/commit/6cde8b6d280f0991ebc25efb3bf0bedd86db3460))
* seven phone ui fixes from the backlog, one device row per install, and a tidier call screen ([#1611](https://github.com/Slim-m-org/slim-m/issues/1611)) ([99c8f6b](https://github.com/Slim-m-org/slim-m/commit/99c8f6b481905f2c058eb3c5f86466e2c49cc862))
* the totp contract script waits until mid step so a step edge cannot refuse its codes ([#1603](https://github.com/Slim-m-org/slim-m/issues/1603)) ([b51670c](https://github.com/Slim-m-org/slim-m/commit/b51670c1736388fa60b6798f0da5c1577b4815ef))

## [0.80.0](https://github.com/Slim-m-org/slim-m/compare/server-v0.79.0...server-v0.80.0) (2026-10-02)


### Bug Fixes

* linking Spotify reports what happened, and the listening box shows cover art and its source ([#1593](https://github.com/Slim-m-org/slim-m/issues/1593)) ([c8f3f3c](https://github.com/Slim-m-org/slim-m/commit/c8f3f3c770c81027524e1ade919519a21ceaade9))

## [0.79.0](https://github.com/Slim-m-org/slim-m/compare/server-v0.78.0...server-v0.79.0) (2026-10-01)


### Features

* /version reports claimed, and an unclaimed Space opens on create-account ([#1562](https://github.com/Slim-m-org/slim-m/issues/1562)) ([067d0cc](https://github.com/Slim-m-org/slim-m/commit/067d0cc593f0eb08fa46837ecfc76c4c3e0912d2))
* an administrator can rename a member or bot, and a refused app launch stops spinning ([#1582](https://github.com/Slim-m-org/slim-m/issues/1582)) ([3512da2](https://github.com/Slim-m-org/slim-m/commit/3512da2acbdee23a75d4909f4aad8881c1121188))
* search the emoji list, refuse standard shortcode names, report identical images, and turn typed :shortcodes: into emoji ([#1581](https://github.com/Slim-m-org/slim-m/issues/1581)) ([de9ed81](https://github.com/Slim-m-org/slim-m/commit/de9ed81e5f9e9264439e695d7bd7c49d0d1460c7))


### Bug Fixes

* backslash escapes, forward and empty-chat glyphs, long role chips, moderator gating, and a signed-out notice ([#1568](https://github.com/Slim-m-org/slim-m/issues/1568)) ([e58013e](https://github.com/Slim-m-org/slim-m/commit/e58013eb3e8cce135590c5aabceded33a577ee86))
* cross-device sync for unread and overrides, last seen, attachment names, mentions in code, hidden characters ([#1567](https://github.com/Slim-m-org/slim-m/issues/1567)) ([a323133](https://github.com/Slim-m-org/slim-m/commit/a323133f4b9f991654b54da04c3142637c5d0d2b))
* **server:** a push for a message with no text previews what it carries ([#1557](https://github.com/Slim-m-org/slim-m/issues/1557)) ([e65cef7](https://github.com/Slim-m-org/slim-m/commit/e65cef73aea9194e38d5c65eafc5b16935b30a5a))
* **server:** bound module tables, memories and instances, stop timed-out wasm, and word traps as sentences ([#1559](https://github.com/Slim-m-org/slim-m/issues/1559)) ([32e2b29](https://github.com/Slim-m-org/slim-m/commit/32e2b299a38ceb71bdcb307eb86876b2a4dd1d44))
* **server:** enforce the two-factor policy for administrators, and five smaller correctness fixes ([#1571](https://github.com/Slim-m-org/slim-m/issues/1571)) ([c1b581d](https://github.com/Slim-m-org/slim-m/commit/c1b581dbc0c957ed65a44f5376c7a565be3a4f7a))
* the call timer reads the call's age from the server, and five more call ui bugs ([#1566](https://github.com/Slim-m-org/slim-m/issues/1566)) ([44f3c8d](https://github.com/Slim-m-org/slim-m/commit/44f3c8d81f8d9c8df06ab6181efc5aa44a6000a1))
* the message preview in a push is an account choice, on by default, so a reinstall or a new device no longer turns it off ([#1583](https://github.com/Slim-m-org/slim-m/issues/1583)) ([8ab0b75](https://github.com/Slim-m-org/slim-m/commit/8ab0b758fb010a50b7595018477068da1c31b238))
* two-factor and account deletion need the password, usernames ignore case, and a clear-totp command ([#1561](https://github.com/Slim-m-org/slim-m/issues/1561)) ([7263973](https://github.com/Slim-m-org/slim-m/commit/7263973d9e3a83f983003b3059ff41117006c90a))

## [0.78.0](https://github.com/Slim-m-org/slim-m/compare/server-v0.77.0...server-v0.78.0) (2026-10-01)


### Features

* hold a reaction to see who left it ([#1551](https://github.com/Slim-m-org/slim-m/issues/1551)) ([27d6660](https://github.com/Slim-m-org/slim-m/commit/27d6660f935cdfe548391bf06d80b53428248c07))


### Bug Fixes

* an unchanged read marker stops waking every socket, and appear-offline survives a relaunch ([#1555](https://github.com/Slim-m-org/slim-m/issues/1555)) ([b376f83](https://github.com/Slim-m-org/slim-m/commit/b376f83c5ecf10246f24b1b837e61e8cdb0f6afb))
* **server,client:** a scene sweep delay near the ceiling no longer crashes the server ([#1538](https://github.com/Slim-m-org/slim-m/issues/1538)) ([b297620](https://github.com/Slim-m-org/slim-m/commit/b297620ac4895446e4328c0dd1b3f9aff8648c7a))
* **server:** fourteen bugs found by using a live deployment as an admin, a member and a bot ([#1546](https://github.com/Slim-m-org/slim-m/issues/1546)) ([8c8832e](https://github.com/Slim-m-org/slim-m/commit/8c8832e2235535c37046c184aad6474a41ba9247))
* **server:** key the module caller id so it cannot be turned back into a user id ([#1543](https://github.com/Slim-m-org/slim-m/issues/1543)) ([8f3f69b](https://github.com/Slim-m-org/slim-m/commit/8f3f69b2689e0328f6dfa517474bae3401f4c361))
* **server:** purge two-factor data on account deletion, and queue racing writes instead of answering 500 ([#1535](https://github.com/Slim-m-org/slim-m/issues/1535)) ([287077e](https://github.com/Slim-m-org/slim-m/commit/287077e3fb2e6e02a11da50a07678525cd5341a1))
* sign-in makes one read-marker request, not one per channel, and stops tripping the rate limiter ([#1554](https://github.com/Slim-m-org/slim-m/issues/1554)) ([cc32100](https://github.com/Slim-m-org/slim-m/commit/cc3210044dda2c42cf1e01ba67b9a9b7bb78531f))

## [0.77.0](https://github.com/Slim-m-org/slim-m/compare/server-v0.76.0...server-v0.77.0) (2026-09-30)


### Features

* durable watch session and watch.tick for a real position readout ([#1527](https://github.com/Slim-m-org/slim-m/issues/1527)) ([7039fc6](https://github.com/Slim-m-org/slim-m/commit/7039fc6526ee7ff081913a1b2516da9fa86eede1))
* files and embeds on a private bot message, and reporting one ([#1494](https://github.com/Slim-m-org/slim-m/issues/1494)) ([29d53ce](https://github.com/Slim-m-org/slim-m/commit/29d53ce959813f5478e3eab5926ac3480484f1b8))
* optional TOTP two-factor authentication ([#1512](https://github.com/Slim-m-org/slim-m/issues/1512)) ([ff1c2c4](https://github.com/Slim-m-org/slim-m/commit/ff1c2c494e1d1763a144c444c5bc4b1f14999389))
* role hoist flag and top hoisted role on member rows ([#1492](https://github.com/Slim-m-org/slim-m/issues/1492)) ([2c1893a](https://github.com/Slim-m-org/slim-m/commit/2c1893ac02e398b1bd9a15b73fa78e9b0c28590f))
* **server:** report a build id on /version ([#1498](https://github.com/Slim-m-org/slim-m/issues/1498)) ([b27c649](https://github.com/Slim-m-org/slim-m/commit/b27c649bb9e9dd75f8c4c6bb85b47a643e27b1c0))


### Bug Fixes

* a channel's notification override decides its badge, not only its push ([#1515](https://github.com/Slim-m-org/slim-m/issues/1515)) ([3b2fa1e](https://github.com/Slim-m-org/slim-m/commit/3b2fa1ecee38ed5a78e20f6f6175e3501aee6718))
* **server:** derive the ws viewing report and the push lifecycle report from one foreground rule ([#1496](https://github.com/Slim-m-org/slim-m/issues/1496)) ([1669839](https://github.com/Slim-m-org/slim-m/commit/166983983af0e46333b46f432518b0aa7e1229c6))
* **server:** refuse to enable a module whose slash keyword another enabled module owns ([#1493](https://github.com/Slim-m-org/slim-m/issues/1493)) ([fadf826](https://github.com/Slim-m-org/slim-m/commit/fadf8265eed00c53adf61f1561e5a557189c2356))
* **server:** remove forwarded copies of originals deleted before copies followed them ([#1495](https://github.com/Slim-m-org/slim-m/issues/1495)) ([755de13](https://github.com/Slim-m-org/slim-m/commit/755de13f26eebf973d11c782352fbe4b4e44847b))
* **server:** ring iOS through its VoIP token, end rings by push, and push mentions and sign-in alerts ([#1479](https://github.com/Slim-m-org/slim-m/issues/1479)) ([e59c12c](https://github.com/Slim-m-org/slim-m/commit/e59c12c195fc8530763110126d96c4c7dd3fba12))
* **server:** validate bot button labels with the shared hidden-char classifier ([#1491](https://github.com/Slim-m-org/slim-m/issues/1491)) ([919aa49](https://github.com/Slim-m-org/slim-m/commit/919aa49b6e6226862013c2a27e123ec36ed24d4f))
* write join_muted in the channel create and mark join_muted channels in the rail and rejoin screen ([#1486](https://github.com/Slim-m-org/slim-m/issues/1486)) ([263117e](https://github.com/Slim-m-org/slim-m/commit/263117e08cd4ab8592371296decb9ea6486cec71))

## [0.76.0](https://github.com/Slim-m-org/slim-m/compare/server-v0.75.0...server-v0.76.0) (2026-09-29)


### Bug Fixes

* **client:** drop an event socket that goes silent and reconnect ([#1470](https://github.com/Slim-m-org/slim-m/issues/1470)) ([9c90818](https://github.com/Slim-m-org/slim-m/commit/9c90818cc25876e98795fee3468697e950819213))
* **server:** keep the dock catalog across the move to Slim-m-org ([#1475](https://github.com/Slim-m-org/slim-m/issues/1475)) ([f254db1](https://github.com/Slim-m-org/slim-m/commit/f254db1967766e73ee0a4bea8d668c79b52a8b95))

## [0.75.0](https://github.com/NC1107/slim-m/compare/server-v0.74.0...server-v0.75.0) (2026-09-29)


### Features

* buttons on bot messages, with private answers to a press ([b49c3cd](https://github.com/NC1107/slim-m/commit/b49c3cd1e5c2319350b6360dbd091d70474abb1f))
* let a bot answer one member privately (ephemeral messages) ([2da9182](https://github.com/NC1107/slim-m/commit/2da9182e94896b69edcda853a7f6ae0945e188cf))
* pre-muted voice channels, a per-channel join_muted default ([5c6cde4](https://github.com/NC1107/slim-m/commit/5c6cde45dfa5ac9aa57877fa92e9f0a08ae1782d))
* **server,client:** a scene can declare motion for the client to play, bounded on both sides ([3fda014](https://github.com/NC1107/slim-m/commit/3fda014d70505a67ca94d230fec5b67409f4b907))
* **server,client:** rich presence, show what a member is listening to (linux MPRIS first) ([1d157a3](https://github.com/NC1107/slim-m/commit/1d157a314d025367b9f5375bf4bdd09019aa579b))
* **server,client:** rotate a webhook's URL in place ([1b09059](https://github.com/NC1107/slim-m/commit/1b090596ee974e9689aae3624202f5c23e64b074))
* **server,client:** turn on module capabilities (kv.store and message.post), approved per module at install ([699c993](https://github.com/NC1107/slim-m/commit/699c99390f2756fc207a313369820d25b22dc221))
* **server,client:** warn an account's other devices when an unfamiliar device signs in ([96e64a8](https://github.com/NC1107/slim-m/commit/96e64a8bffbe66d861df534fa6b77cc0c666c470))
* **server:** bot-contributed message menu entries and call controls ([#1456](https://github.com/NC1107/slim-m/issues/1456)) ([e63a343](https://github.com/NC1107/slim-m/commit/e63a3432c0971203027b44b9b9b1ccce57705dab))
* **server:** hand modules an opaque caller id, and document what run receives ([#1431](https://github.com/NC1107/slim-m/issues/1431)) ([4bc6439](https://github.com/NC1107/slim-m/commit/4bc6439719204a49722826a3bf240029b5839a49))
* **server:** number moderation events and carry the head in the ws hello ([#1417](https://github.com/NC1107/slim-m/issues/1417)) ([fa50f85](https://github.com/NC1107/slim-m/commit/fa50f85dae6cea8104e0483bcca9de087739032d))
* **server:** surface a webhook post's own username label on list, sync and live frames ([#1416](https://github.com/NC1107/slim-m/issues/1416)) ([c4ed6a6](https://github.com/NC1107/slim-m/commit/c4ed6a6a12ad63851a4a197ada871eac0d5d328f))


### Bug Fixes

* **server,client:** refuse and mark code blocks that hide text-direction characters ([8d8b8ef](https://github.com/NC1107/slim-m/commit/8d8b8efe590bdb9c7ce399c5dedb131f1e48befa))
* **server:** name the refused permission bits in an overwrite write's 403 ([#1446](https://github.com/NC1107/slim-m/issues/1446)) ([681b9da](https://github.com/NC1107/slim-m/commit/681b9daf51653101bdce59a8a8ccc5ecad915060))
* **server:** read state travels between an account's devices ([#1408](https://github.com/NC1107/slim-m/issues/1408)) ([d68ccf5](https://github.com/NC1107/slim-m/commit/d68ccf50906d7af1883faf35dd45735a438b3e80))
* **server:** refuse colliding command names, untypable keywords and hidden characters in a module manifest ([b185e70](https://github.com/NC1107/slim-m/commit/b185e70bffbd4ade99c8e5a8fa07e4954a181f45))
* **server:** remove forwarded snapshots when their original is deleted or ages out ([4395e67](https://github.com/NC1107/slim-m/commit/4395e67af863decc742ac4558c3d57ff246c188d))
* **server:** run the stored code block, not the input a client sends ([59689a3](https://github.com/NC1107/slim-m/commit/59689a3c194f49b7b781ffd3f3d2750b6e46b72e))


### Performance Improvements

* **server:** key viewing reports by user so a frame never scans the whole map ([#1448](https://github.com/NC1107/slim-m/issues/1448)) ([273a8a8](https://github.com/NC1107/slim-m/commit/273a8a8c0f2acbbb06fd6d657c022716cf0e3539))
* **server:** resolve a call message's record once, not per ws subscriber ([#1450](https://github.com/NC1107/slim-m/issues/1450)) ([3a228c4](https://github.com/NC1107/slim-m/commit/3a228c42b08ccec2e60f0d67ee80ecdb2a33420d))

## [0.74.0](https://github.com/NC1107/slim-m/compare/server-v0.73.0...server-v0.74.0) (2026-09-28)


### Bug Fixes

* **server:** refuse an over-ceiling module scene instead of cutting its JSON ([#1388](https://github.com/NC1107/slim-m/issues/1388)) ([899262a](https://github.com/NC1107/slim-m/commit/899262a4bef5c047499a7275e74c3d1f54a1eb47))

## [0.73.0](https://github.com/NC1107/slim-m/compare/server-v0.72.0...server-v0.73.0) (2026-09-25)


### Features

* per-weekday notification schedule with an off-hours policy ([#1376](https://github.com/NC1107/slim-m/issues/1376)) ([161bf69](https://github.com/NC1107/slim-m/commit/161bf69368c43cadec4e214fbb86fe73a962604d))

## [0.72.0](https://github.com/NC1107/slim-m/compare/server-v0.71.0...server-v0.72.0) (2026-09-25)


### Features

* **server,client:** add a member.joined event so a bot can greet a new member ([#1357](https://github.com/NC1107/slim-m/issues/1357)) ([2487aa7](https://github.com/NC1107/slim-m/commit/2487aa79bca6bf901d371e6e2cdda8f1754d7c80))

## [0.71.0](https://github.com/NC1107/slim-m/compare/server-v0.70.0...server-v0.71.0) (2026-09-25)


### Features

* **server,client:** mint, list, rename and revoke webhooks ([#1332](https://github.com/NC1107/slim-m/issues/1332)) ([ca3028a](https://github.com/NC1107/slim-m/commit/ca3028a30ada1a22c041dbbc85258eba8b9e8103))
* **server:** accept embeds on the webhook and bot send routes ([#1326](https://github.com/NC1107/slim-m/issues/1326)) ([9972dbe](https://github.com/NC1107/slim-m/commit/9972dbe30f5c9bece882eab718953b9e59203cd0))
* **server:** add GET for a single message ([#1336](https://github.com/NC1107/slim-m/issues/1336)) ([6683797](https://github.com/NC1107/slim-m/commit/668379785816181d116518c828f91fc1c99368a6))
* **server:** add pronouns, about, profile colour and named devices ([#1330](https://github.com/NC1107/slim-m/issues/1330)) ([ef33d78](https://github.com/NC1107/slim-m/commit/ef33d7827e03c74222e61322fec67bdc126e6c90))
* **server:** bot command registration (decision 0031) ([#1325](https://github.com/NC1107/slim-m/issues/1325)) ([017666c](https://github.com/NC1107/slim-m/commit/017666c1e547d22d423add4d56a57d06c5e869db))
* **server:** declared bot permissions, a managed role, and a real audit trail ([#1328](https://github.com/NC1107/slim-m/issues/1328)) ([8ec694c](https://github.com/NC1107/slim-m/commit/8ec694c2894e84c5784813958333a7b7421d9342))
* **server:** live join/leave/screen-share voice events from LiveKit webhooks ([#1334](https://github.com/NC1107/slim-m/issues/1334)) ([34ca037](https://github.com/NC1107/slim-m/commit/34ca03787a403e6d1a161dfc9ca36dffc126b2f2))
* **server:** role reordering, per-role member counts, and batch channel overwrites ([#1331](https://github.com/NC1107/slim-m/issues/1331)) ([6514c3f](https://github.com/NC1107/slim-m/commit/6514c3f89825b4a2d9bb72f33dd6f57a5caeab5d))
* **server:** store and enrich message embeds (stage 3, read side) ([#1323](https://github.com/NC1107/slim-m/issues/1323)) ([df65334](https://github.com/NC1107/slim-m/commit/df6533472b62a0ea9a7ab4ad8c32ba02955c9023))


### Bug Fixes

* **server:** drop a bot from the default list once it leaves the Space ([#1309](https://github.com/NC1107/slim-m/issues/1309)) ([135d74e](https://github.com/NC1107/slim-m/commit/135d74e9d9e3e4667dd2778c936aa713fce284e2))
* **server:** gate a code run against the message's own app surface ([#1317](https://github.com/NC1107/slim-m/issues/1317)) ([ac628cd](https://github.com/NC1107/slim-m/commit/ac628cde2d94e14cbc754abeca1baf336ae95562))
* **server:** make module install atomic and verify the approved sha at run time ([#1321](https://github.com/NC1107/slim-m/issues/1321)) ([6c8b1e0](https://github.com/NC1107/slim-m/commit/6c8b1e0aa455c181f84b1efd0f545d9ae7e6c5d7))

## [0.70.0](https://github.com/NC1107/slim-m/compare/server-v0.69.0...server-v0.70.0) (2026-09-23)


### Features

* **server:** incoming webhooks, stages 1-2 (mint, revoke, delivery) ([#1290](https://github.com/NC1107/slim-m/issues/1290)) ([87567ea](https://github.com/NC1107/slim-m/commit/87567ea6be64e0368f04a793e39f77fa9616aa92))


### Bug Fixes

* **server:** revive a bot's token when its removal is undone ([#1301](https://github.com/NC1107/slim-m/issues/1301)) ([1791889](https://github.com/NC1107/slim-m/commit/1791889dbe2b6043d064eb6b1508b33deefcd593))

## [0.69.0](https://github.com/NC1107/slim-m/compare/server-v0.68.0...server-v0.69.0) (2026-09-23)


### Features

* **server,client:** add a Private toggle to channel creation ([#1279](https://github.com/NC1107/slim-m/issues/1279)) ([b96d83f](https://github.com/NC1107/slim-m/commit/b96d83f9ea643fc6c56ddd6b883bc6084c22b719))


### Bug Fixes

* **client:** narrow the member pane to who can view the channel ([#1272](https://github.com/NC1107/slim-m/issues/1272)) ([e5ce199](https://github.com/NC1107/slim-m/commit/e5ce19989f5e0ef635e2600eaff5e9b005808392))
* **client:** render a thread's parent message above its replies ([#1280](https://github.com/NC1107/slim-m/issues/1280)) ([3d686e6](https://github.com/NC1107/slim-m/commit/3d686e6fc7a8df6e679b1287d6a1a8d43f170013))

## [0.68.0](https://github.com/NC1107/slim-m/compare/server-v0.67.0...server-v0.68.0) (2026-09-22)


### Features

* account recovery in settings, image gallery paging, and the audit follow-ups ([#1267](https://github.com/NC1107/slim-m/issues/1267)) ([05c2508](https://github.com/NC1107/slim-m/commit/05c2508e0a33a6f61e94fa5745bf7ffec7293470))


### Bug Fixes

* **server:** close an invite-code disclosure and make bot revocation cut the socket ([#1263](https://github.com/NC1107/slim-m/issues/1263)) ([776c97e](https://github.com/NC1107/slim-m/commit/776c97e73f305eeb6454099f9057c18b51791ceb))
* **server:** reserve the code-runner id at install, and stop re-loading roles per extension point ([#1264](https://github.com/NC1107/slim-m/issues/1264)) ([162c58c](https://github.com/NC1107/slim-m/commit/162c58c2a7bf6a5ff93adbc8d1794cf184ac6899))

## [0.67.0](https://github.com/NC1107/slim-m/compare/server-v0.66.0...server-v0.67.0) (2026-09-21)


### Miscellaneous Chores

* **server:** Synchronize server versions

## [0.66.0](https://github.com/NC1107/slim-m/compare/server-v0.65.0...server-v0.66.0) (2026-09-21)


### Features

* bot accounts, end to end ([#1237](https://github.com/NC1107/slim-m/issues/1237)) ([ea505cf](https://github.com/NC1107/slim-m/commit/ea505cfc80a7894618518119532e40447f01a0b2))
* let an administrator delete a member's account outright ([#1257](https://github.com/NC1107/slim-m/issues/1257)) ([3e039e1](https://github.com/NC1107/slim-m/commit/3e039e189e1de0caa461f1c62135e707eb07a75d))
* mark a channel or DM as unread ([#1231](https://github.com/NC1107/slim-m/issues/1231)) ([b477416](https://github.com/NC1107/slim-m/commit/b477416dc2887afcdcc73235c1e20384da6f3638))
* say which accounts are bots ([#1240](https://github.com/NC1107/slim-m/issues/1240)) ([ce4c68d](https://github.com/NC1107/slim-m/commit/ce4c68df80edb33a7123d952e71013c5fd84a868))
* **server:** wake somebody whose call went unanswered ([#1241](https://github.com/NC1107/slim-m/issues/1241)) ([373cbac](https://github.com/NC1107/slim-m/commit/373cbacc2f039e7fae3b4d2a734a3bfdeb5b2ad3))


### Bug Fixes

* **server:** let a text-only deployment actually start ([#1222](https://github.com/NC1107/slim-m/issues/1222)) ([31b945b](https://github.com/NC1107/slim-m/commit/31b945b66b28188afeef942e358d43ce612a2c19))
* **server:** scope invite listing and revocation to their creator ([#1252](https://github.com/NC1107/slim-m/issues/1252)) ([c412135](https://github.com/NC1107/slim-m/commit/c41213506432bb92711af3667e4e2f52abfb6d6a))
* stop a lost rotation response from signing the client out ([#1232](https://github.com/NC1107/slim-m/issues/1232)) ([57da9b3](https://github.com/NC1107/slim-m/commit/57da9b3c5d68e9e81757226daae96e22256ae50e))
* the small findings from the audit, and two claims that were not true ([#1253](https://github.com/NC1107/slim-m/issues/1253)) ([9004ead](https://github.com/NC1107/slim-m/commit/9004ead6f170ce9a2dbc2f9cdbee7367c5105987))
* three rough edges an operator hits before anything works ([#1244](https://github.com/NC1107/slim-m/issues/1244)) ([f4e20f2](https://github.com/NC1107/slim-m/commit/f4e20f2828b40eb0d4cc1580b76559e976cb5bdf))

## [0.65.0](https://github.com/NC1107/slim-m/compare/server-v0.64.0...server-v0.65.0) (2026-09-16)


### Features

* **server:** broker code execution through a self-hosted Piston instance ([#1216](https://github.com/NC1107/slim-m/issues/1216)) ([5deb9c7](https://github.com/NC1107/slim-m/commit/5deb9c7d6a38ebbb40df1170b594bbcd713b2949))
* **server:** show a YouTube video's channel on its link preview ([#1213](https://github.com/NC1107/slim-m/issues/1213)) ([369cdab](https://github.com/NC1107/slim-m/commit/369cdab8fe9cea2e4b1427f1b017ec954497a361))


### Bug Fixes

* double the signup limit, and stop a small board filling the screen ([#1205](https://github.com/NC1107/slim-m/issues/1205)) ([8bfda8c](https://github.com/NC1107/slim-m/commit/8bfda8c904634c0559646212d8ac48429834d135))
* **server:** carry app surfaces and polls on the live message.created frame ([#1210](https://github.com/NC1107/slim-m/issues/1210)) ([060ff14](https://github.com/NC1107/slim-m/commit/060ff140d3a553f6247369559c26013bfc358f47))

## [0.64.0](https://github.com/NC1107/slim-m/compare/server-v0.63.0...server-v0.64.0) (2026-09-15)


### Features

* add per-route request timing and an admin metrics screen ([#1200](https://github.com/NC1107/slim-m/issues/1200)) ([91a8891](https://github.com/NC1107/slim-m/commit/91a8891cbbea647f2bfd04c74f24f9dc51e24f13))
* **server:** refuse new websocket connections when memory is low ([#1201](https://github.com/NC1107/slim-m/issues/1201)) ([d4a7f9b](https://github.com/NC1107/slim-m/commit/d4a7f9b5c983db9f99ddb8e0ec310ce181f4f73d))

## [0.63.0](https://github.com/NC1107/slim-m/compare/server-v0.62.0...server-v0.63.0) (2026-09-15)


### Features

* show which channels are private ([#1193](https://github.com/NC1107/slim-m/issues/1193)) ([2307356](https://github.com/NC1107/slim-m/commit/230735668c7b85a83546a165d5bf32dc60aeb8ae))

## [0.62.0](https://github.com/NC1107/slim-m/compare/server-v0.61.0...server-v0.62.0) (2026-09-14)


### Features

* opt-in automatic updates, and a server floor that forces one ([#1184](https://github.com/NC1107/slim-m/issues/1184)) ([f73fd49](https://github.com/NC1107/slim-m/commit/f73fd49247161509124d20e8688b2c7841927837))

## [0.61.0](https://github.com/NC1107/slim-m/compare/server-v0.60.0...server-v0.61.0) (2026-09-14)


### Bug Fixes

* address the audit's confirmed findings across sync, ci and the client ([#1171](https://github.com/NC1107/slim-m/issues/1171)) ([67316a3](https://github.com/NC1107/slim-m/commit/67316a3be2af6fd9c0a3e0a292edf7293f98266c))

## [0.60.0](https://github.com/NC1107/slim-m/compare/server-v0.59.0...server-v0.60.0) (2026-09-13)


### Features

* a DM call leaves a record in the transcript ([#1168](https://github.com/NC1107/slim-m/issues/1168)) ([3e8809f](https://github.com/NC1107/slim-m/commit/3e8809fb5d2dffe8dcaa7720c5a057452b3ca8b9))


### Bug Fixes

* **client:** say why a session ended, and log every refresh rejection ([#1167](https://github.com/NC1107/slim-m/issues/1167)) ([0f56716](https://github.com/NC1107/slim-m/commit/0f567162a73e289d4531bf27649163dfe5697d33))
* **server:** give module runs their own rate-limit class ([#1159](https://github.com/NC1107/slim-m/issues/1159)) ([2f6b0ee](https://github.com/NC1107/slim-m/commit/2f6b0ee4345ecc97c150003920ab908238a9d94c))

## [0.59.0](https://github.com/NC1107/slim-m/compare/server-v0.58.0...server-v0.59.0) (2026-09-11)


### Bug Fixes

* an avatar change reaches other devices without a restart ([#1138](https://github.com/NC1107/slim-m/issues/1138)) ([fad3339](https://github.com/NC1107/slim-m/commit/fad3339d6a0d85f2267b2bebb2a18c088617450d))
* say which server sign-in connects to, and make its code checkable ([#1144](https://github.com/NC1107/slim-m/issues/1144)) ([cf109c1](https://github.com/NC1107/slim-m/commit/cf109c1d2d66a592478e83daae195c54f439dc32))

## [0.58.0](https://github.com/NC1107/slim-m/compare/server-v0.57.0...server-v0.58.0) (2026-09-09)


### Features

* **server:** make fileReport idempotent by a client-minted id ([#1128](https://github.com/NC1107/slim-m/issues/1128)) ([8005672](https://github.com/NC1107/slim-m/commit/8005672f3be395116a33464a0fdfdcb1744a0ab4))

## [0.57.0](https://github.com/NC1107/slim-m/compare/server-v0.56.0...server-v0.57.0) (2026-09-08)


### Features

* apps launcher - launch a module as a shared, interactive surface ([#1109](https://github.com/NC1107/slim-m/issues/1109)) ([8c83a68](https://github.com/NC1107/slim-m/commit/8c83a680099a9be4f7a8474d1584baeb6da0b26b))
* language-matched code-block runners and a command panel ([#1096](https://github.com/NC1107/slim-m/issues/1096)) ([20cc16e](https://github.com/NC1107/slim-m/commit/20cc16e181f137b0ee6d92ec6b90a533b92d0715))
* **link-preview:** click-to-play for YouTube video links ([#1084](https://github.com/NC1107/slim-m/issues/1084)) ([c091db8](https://github.com/NC1107/slim-m/commit/c091db83fa938d2639a6b53b1e7df4af71d2e98b))
* module slash commands in the composer ([#1100](https://github.com/NC1107/slim-m/issues/1100)) ([73f50aa](https://github.com/NC1107/slim-m/commit/73f50aaa7d1727f4525202a43b874e8ad4941394))
* **module-runtime:** kv.store reference capability (off by default) ([#1115](https://github.com/NC1107/slim-m/issues/1115)) ([e667fa8](https://github.com/NC1107/slim-m/commit/e667fa88b4d892c6ee02f818d7866cd8e2d8407d))
* **module-runtime:** scaffold the host-import surface, off by default ([#1114](https://github.com/NC1107/slim-m/issues/1114)) ([78812f8](https://github.com/NC1107/slim-m/commit/78812f84c87f17c7d608afadf749e14781b550e9))
* per-channel slow mode ([#1085](https://github.com/NC1107/slim-m/issues/1085)) ([5da23c3](https://github.com/NC1107/slim-m/commit/5da23c30f89aa6931eeb7c8d92b109a7bd94f981))
* read a channel's permission overwrites before editing them ([#1071](https://github.com/NC1107/slim-m/issues/1071)) ([94f9dcd](https://github.com/NC1107/slim-m/commit/94f9dcd229d49bb909bbe915cbe000491052b1ff))
* run a code block and see its output ([#1092](https://github.com/NC1107/slim-m/issues/1092)) ([1355afa](https://github.com/NC1107/slim-m/commit/1355afad31ce1cc616158514d39717df443ab551))
* **server,client:** operator-visible storage view ([#1077](https://github.com/NC1107/slim-m/issues/1077)) ([57bed6b](https://github.com/NC1107/slim-m/commit/57bed6bd8a7bb325f38f2dd1bd30ae21a778dce0))
* **server:** cross-channel message search (GET /search/messages) ([#1074](https://github.com/NC1107/slim-m/issues/1074)) ([1f7b8bd](https://github.com/NC1107/slim-m/commit/1f7b8bdff99ee4d8b182e134b816b98b47e779a7))
* **server:** module runtime host running installed modules in a wasmi sandbox ([#1091](https://github.com/NC1107/slim-m/issues/1091)) ([4d1004b](https://github.com/NC1107/slim-m/commit/4d1004b9d53697afce1890620450cd3800cfcb97))
* **server:** module system foundation - the Dock (Phase 1+2) ([#1089](https://github.com/NC1107/slim-m/issues/1089)) ([415d0ec](https://github.com/NC1107/slim-m/commit/415d0ec092dc57818442b1b28f4643106e7b61a2))
* shared code-block output ([#1101](https://github.com/NC1107/slim-m/issues/1101)) ([f4876e8](https://github.com/NC1107/slim-m/commit/f4876e8702f3b63db5666c18885def85f50e32f2))
* unread mention badge on the channel rail ([#1075](https://github.com/NC1107/slim-m/issues/1075)) ([2eb27cf](https://github.com/NC1107/slim-m/commit/2eb27cf5691dfcf000b44f98b6cd6df3b3dd5140))


### Bug Fixes

* **link-preview:** build YouTube previews from the URL, not a scrape ([#1102](https://github.com/NC1107/slim-m/issues/1102)) ([29ebdcb](https://github.com/NC1107/slim-m/commit/29ebdcbfae9b1285068d3960ce24227bf0639103))
* **server:** bound module response regions and cache compiled wasm ([#1117](https://github.com/NC1107/slim-m/issues/1117)) ([74cea80](https://github.com/NC1107/slim-m/commit/74cea80b139e6675e4f7fc04245dcb6b6d48d2fa))
* **server:** code_runs delete trigger and moderation-history indexes ([#1118](https://github.com/NC1107/slim-m/issues/1118)) ([d04b277](https://github.com/NC1107/slim-m/commit/d04b2775c7c4bae6d5b3e66a06d567747c3ccef0))
* **server:** unbreak main - too-many-arguments on record_code_run ([#1107](https://github.com/NC1107/slim-m/issues/1107)) ([6b1b33f](https://github.com/NC1107/slim-m/commit/6b1b33f79c59a619aacb460c9dc19a33de7598ee))


### Performance Improvements

* **server:** Arc-share heavy broadcast payloads ([#1079](https://github.com/NC1107/slim-m/issues/1079)) ([54fb0d4](https://github.com/NC1107/slim-m/commit/54fb0d4b53411a63a0fa85211538ff3507dca500))
* **server:** cache presence visibility per connection ([#1073](https://github.com/NC1107/slim-m/issues/1073)) ([046a20c](https://github.com/NC1107/slim-m/commit/046a20cb01152ec8c5786ef17ce472d668ec9e78))
* **server:** split ephemeral canvas events onto their own broadcast channel ([#1082](https://github.com/NC1107/slim-m/issues/1082)) ([9c6d7eb](https://github.com/NC1107/slim-m/commit/9c6d7eb72c895bc0c3adf1db4d6d4b4416ef80f2))
* **test:** seed test DBs from a migrated template ([#1116](https://github.com/NC1107/slim-m/issues/1116)) ([5d5d8cc](https://github.com/NC1107/slim-m/commit/5d5d8ccd7229e655e0538f5b53508f56d62d13f1))
* **test:** seed the feed-budget canvas objects in one transaction ([#1086](https://github.com/NC1107/slim-m/issues/1086)) ([642e1e3](https://github.com/NC1107/slim-m/commit/642e1e31b13672b9ee0919ab4d5ea14264f475a2))

## [0.56.0](https://github.com/NC1107/slim-m/compare/server-v0.55.0...server-v0.56.0) (2026-09-04)


### Features

* create a channel from the rail, in the section you asked from ([#1040](https://github.com/NC1107/slim-m/issues/1040)) ([1bc0e6c](https://github.com/NC1107/slim-m/commit/1bc0e6cc9c1e0cd5203305439eaab0d89b93a807))
* keep a message for yourself ([#1045](https://github.com/NC1107/slim-m/issues/1045)) ([466a9c7](https://github.com/NC1107/slim-m/commit/466a9c7ecb3c7eb133d2f7d66464968df7cfb1ee))
* link previews (unfurl) behind an SSRF guard ([#1067](https://github.com/NC1107/slim-m/issues/1067)) ([0c267fe](https://github.com/NC1107/slim-m/commit/0c267fe3fdd756a4aebeb1f8ac11ed110d405ac8))
* model forwarded messages instead of composing them into text ([#1039](https://github.com/NC1107/slim-m/issues/1039)) ([bee7e20](https://github.com/NC1107/slim-m/commit/bee7e2084d746c7120e587adbf1fd278dfb1de23))
* **server:** a selected GIF is stored under a name from its title ([#1062](https://github.com/NC1107/slim-m/issues/1062)) ([e10b87b](https://github.com/NC1107/slim-m/commit/e10b87b62be97e7972e587ea9b5cc7454ffc05fb))


### Bug Fixes

* an edit keeps the forward, and may empty a forward's note ([#1044](https://github.com/NC1107/slim-m/issues/1044)) ([a8a0c51](https://github.com/NC1107/slim-m/commit/a8a0c512c2922aa156d247dd3e0b12483baa4b03))
* **server:** a deleted category cannot be created into ([#1042](https://github.com/NC1107/slim-m/issues/1042)) ([056f3b9](https://github.com/NC1107/slim-m/commit/056f3b9359f01adda8696c0427f150316525d6a0))
* **server:** deleting an account takes everything it should, and a gate says so ([#1048](https://github.com/NC1107/slim-m/issues/1048)) ([b328d46](https://github.com/NC1107/slim-m/commit/b328d469bad07fec5f83240140b2d7bfcb757873))
* **server:** forwarding a forward carries the first original ([#1041](https://github.com/NC1107/slim-m/issues/1041)) ([1faa5d4](https://github.com/NC1107/slim-m/commit/1faa5d45df4bdbf324c065551412d42812b72abe))
* **server:** the uploader can fetch their own not-yet-attached upload ([#1061](https://github.com/NC1107/slim-m/issues/1061)) ([0d2e236](https://github.com/NC1107/slim-m/commit/0d2e23627e605c20f5b4a3781724bbe77786a403))
* six findings from a multi-agent audit of this session's work ([#1049](https://github.com/NC1107/slim-m/issues/1049)) ([7092c33](https://github.com/NC1107/slim-m/commit/7092c3395c04fde56a89d4c4d814b69ee9c1a5a8))


### Performance Improvements

* **server:** /sync batches its permission checks ([#1059](https://github.com/NC1107/slim-m/issues/1059)) ([b062fdd](https://github.com/NC1107/slim-m/commit/b062fdd07281ef2e9df5f6843a8bc1663f1ed718))

## [0.55.0](https://github.com/NC1107/slim-m/compare/server-v0.54.0...server-v0.55.0) (2026-09-01)


### Bug Fixes

* gif panel fits beside the keyboard, and a stale pick reloads ([#1029](https://github.com/NC1107/slim-m/issues/1029)) ([00f6848](https://github.com/NC1107/slim-m/commit/00f68480db3d5ad2d4a3c1eb5217b2dbcc030f68))

## [0.54.0](https://github.com/NC1107/slim-m/compare/server-v0.53.0...server-v0.54.0) (2026-09-01)


### Features

* moderate several members in one act ([#1019](https://github.com/NC1107/slim-m/issues/1019)) ([760c985](https://github.com/NC1107/slim-m/commit/760c985450a123be6eed70376a5d3a3ef2baadfe))

## [0.53.0](https://github.com/NC1107/slim-m/compare/server-v0.52.0...server-v0.53.0) (2026-08-31)


### Miscellaneous Chores

* **server:** Synchronize server versions

## [0.52.0](https://github.com/NC1107/slim-m/compare/server-v0.51.0...server-v0.52.0) (2026-08-31)


### Features

* add [@role](https://github.com/role) mentions ([#1010](https://github.com/NC1107/slim-m/issues/1010)) ([5aee7be](https://github.com/NC1107/slim-m/commit/5aee7be1698c4847a81d0dcd27e2e7a7a65806ac))


### Bug Fixes

* **server:** a hidden DM must not hide its call from moderation ([#1013](https://github.com/NC1107/slim-m/issues/1013)) ([c46c4cb](https://github.com/NC1107/slim-m/commit/c46c4cb1f60467f3c1acc9a1ee4805e8df890548))
* **server:** a keepalive must not answer a ring ([#1012](https://github.com/NC1107/slim-m/issues/1012)) ([1176699](https://github.com/NC1107/slim-m/commit/11766997bc60421f39a13731fedd52759cd918fd))
* **server:** claim a call ring before recording the join ([#1011](https://github.com/NC1107/slim-m/issues/1011)) ([69753ea](https://github.com/NC1107/slim-m/commit/69753eaf37139d232edd80586194b72662a7a71a))
* **server:** give a DM ring its own rate-limit class ([#1009](https://github.com/NC1107/slim-m/issues/1009)) ([c930dba](https://github.com/NC1107/slim-m/commit/c930dbafe6c29261963a8d541fa2968b0215a97c))
* **server:** keep the two anonymization promises the schema makes ([#1014](https://github.com/NC1107/slim-m/issues/1014)) ([07272a8](https://github.com/NC1107/slim-m/commit/07272a850e2970cc848aaded8c153fbf3ac107ad))

## [0.51.0](https://github.com/NC1107/slim-m/compare/server-v0.50.0...server-v0.51.0) (2026-08-31)


### Bug Fixes

* **server:** restore applied migration bytes to unbreak production ([#1001](https://github.com/NC1107/slim-m/issues/1001)) ([5f6cdf5](https://github.com/NC1107/slim-m/commit/5f6cdf5808617cdf77e825c11f7dcb8ed1a1e667))

## [0.50.0](https://github.com/NC1107/slim-m/compare/server-v0.49.0...server-v0.50.0) (2026-08-30)


### Features

* **server,client:** ring the other side of a DM call and release it if unanswered ([#993](https://github.com/NC1107/slim-m/issues/993)) ([cc62b65](https://github.com/NC1107/slim-m/commit/cc62b651667627819aad89f92fa82180594b6a48))


### Bug Fixes

* **license:** carry PolyForm in the files the ring PR added ([#997](https://github.com/NC1107/slim-m/issues/997)) ([311b78d](https://github.com/NC1107/slim-m/commit/311b78ddfe677498f8f3caf5b118a6b4e79c6166))

## [0.49.0](https://github.com/NC1107/slim-m/compare/server-v0.48.0...server-v0.49.0) (2026-08-30)


### Features

* **client,server:** add a canvas to DMs for 1-on-1 working sessions ([#990](https://github.com/NC1107/slim-m/issues/990)) ([7ccc0ec](https://github.com/NC1107/slim-m/commit/7ccc0ec5aab84b8faa430b53974b00c8a267fa7c))
* **server,client:** let a DM be closed out of the sidebar ([#991](https://github.com/NC1107/slim-m/issues/991)) ([5844786](https://github.com/NC1107/slim-m/commit/58447865ae74f9e8bae7834cd3f3253f53d67604))

## [0.48.0](https://github.com/NC1107/slim-m/compare/server-v0.47.1...server-v0.48.0) (2026-08-30)


### Features

* **server,client:** add quiet hours for notifications ([#981](https://github.com/NC1107/slim-m/issues/981)) ([28ba783](https://github.com/NC1107/slim-m/commit/28ba783aac18367d3f72e3de49e60f460787b3e4))
* **server:** add private per-user notes ([#975](https://github.com/NC1107/slim-m/issues/975)) ([bd49e6c](https://github.com/NC1107/slim-m/commit/bd49e6ce4ad2ae11ffd047c3efabcbdb6bb5d25a))


### Bug Fixes

* **server:** make the klipy gif provider actually parse real responses ([#984](https://github.com/NC1107/slim-m/issues/984)) ([b87a65b](https://github.com/NC1107/slim-m/commit/b87a65b7bdbeab42c64de383b8d9254048ed5c05))

## [0.47.1](https://github.com/NC1107/slim-m/compare/server-v0.47.0...server-v0.47.1) (2026-08-28)


### Bug Fixes

* **server:** give cheap authenticated reads their own rate-limit class ([#949](https://github.com/NC1107/slim-m/issues/949)) ([f30adca](https://github.com/NC1107/slim-m/commit/f30adcad9eb531afc10b8fc5257b0ecd3ea16b3e))

## [0.47.0](https://github.com/NC1107/slim-m/compare/server-v0.46.0...server-v0.47.0) (2026-08-28)


### Features

* **server:** bulk-add custom emoji in one rate-limit charge ([#932](https://github.com/NC1107/slim-m/issues/932)) ([8243bac](https://github.com/NC1107/slim-m/commit/8243bacb1b92d62f55eb18a24f16b617433ea9e0))

## [0.46.0](https://github.com/NC1107/slim-m/compare/server-v0.45.2...server-v0.46.0) (2026-08-27)


### Features

* **server:** bulk-delete a raider's recent messages by author and window ([#922](https://github.com/NC1107/slim-m/issues/922)) ([1b9ee57](https://github.com/NC1107/slim-m/commit/1b9ee57893aeb60f5dcd828b2280f86b51d73728))
* **server:** let a reporter check their own report's status ([#923](https://github.com/NC1107/slim-m/issues/923)) ([5ebae4d](https://github.com/NC1107/slim-m/commit/5ebae4d74ba5f95ebdf2d5cc6634aa0869c0819c))

## [0.45.2](https://github.com/NC1107/slim-m/compare/server-v0.45.1...server-v0.45.2) (2026-08-27)


### Bug Fixes

* **server:** give active_hours and memory_samples their own analytics window start ([#892](https://github.com/NC1107/slim-m/issues/892)) ([90b8503](https://github.com/NC1107/slim-m/commit/90b8503191247cb111da27973410b183324ad69c))
* **server:** record a moderation audit row for a single message delete ([#897](https://github.com/NC1107/slim-m/issues/897)) ([52875d5](https://github.com/NC1107/slim-m/commit/52875d5e8917002ce6059c75ec15ee58ae144006))
* **server:** stop a failed attachment commit from orphaning its temp file ([#894](https://github.com/NC1107/slim-m/issues/894)) ([d1f25cf](https://github.com/NC1107/slim-m/commit/d1f25cf10af59333dcd31ce9d4c0c480ba8e3617))

## [0.45.1](https://github.com/NC1107/slim-m/compare/server-v0.45.0...server-v0.45.1) (2026-08-26)


### Bug Fixes

* **client:** size sheets to content on desktop, use AppErrorState, close token drift ([#880](https://github.com/NC1107/slim-m/issues/880)) ([b2c7080](https://github.com/NC1107/slim-m/commit/b2c70803c643c84c99273b45e1724eb8d928f6bc))
* prevent reset from deleting failed sends, purge avatar on account delete, real reconnect jitter ([#877](https://github.com/NC1107/slim-m/issues/877)) ([f6895f4](https://github.com/NC1107/slim-m/commit/f6895f494c1ad3558470345ba88a93b36f0810f0))
* restore the avatar purge, failed-send-safe reset, and real jitter ([#889](https://github.com/NC1107/slim-m/issues/889)) ([1548449](https://github.com/NC1107/slim-m/commit/154844900d1e3f8d6e14824047ce43c926fc95cb))


### Performance Improvements

* **server:** batch presence/author/roster lookups that ran per-id ([#878](https://github.com/NC1107/slim-m/issues/878)) ([92ac305](https://github.com/NC1107/slim-m/commit/92ac3058c1128dd9c4cfa07735371939fd9ef1b2))

## [0.45.0](https://github.com/NC1107/slim-m/compare/server-v0.44.0...server-v0.45.0) (2026-08-25)


### Features

* a space-wide screen-share quality ceiling ([#874](https://github.com/NC1107/slim-m/issues/874)) ([22292e2](https://github.com/NC1107/slim-m/commit/22292e2ff54f6e7f26a42033cde726b8155de440))

## [0.44.0](https://github.com/NC1107/slim-m/compare/server-v0.43.0...server-v0.44.0) (2026-08-25)


### Features

* **api:** make channel, category and role creation idempotent ([#726](https://github.com/NC1107/slim-m/issues/726)) ([48bd8ab](https://github.com/NC1107/slim-m/commit/48bd8ab377889ca4f71f6c48e08967c810172faa))
* make the per-channel canvas object cap a space setting ([#844](https://github.com/NC1107/slim-m/issues/844)) ([55b123a](https://github.com/NC1107/slim-m/commit/55b123a30c0a80e230c2216d56438bd668b34162))
* **moderation:** server foundation for report history and live sync (MOD4, MOD7) ([#732](https://github.com/NC1107/slim-m/issues/732)) ([882ebcd](https://github.com/NC1107/slim-m/commit/882ebcd32ed44c2aee9d047cc5c9dcc996071a6b))
* **moderation:** show a timed-out member the reason and expiry (MOD6) ([#736](https://github.com/NC1107/slim-m/issues/736)) ([d0ef529](https://github.com/NC1107/slim-m/commit/d0ef5299a1c2ef5a476b2c9c61ed2ea521d94805))
* **moderation:** surface the registration invite to moderators (MOD9) ([#727](https://github.com/NC1107/slim-m/issues/727)) ([ef48f30](https://github.com/NC1107/slim-m/commit/ef48f306654cba0627a4585f2231ba6de13e2deb))
* **server:** stream attachment uploads to disk and raise the cap to 1 GiB ([#843](https://github.com/NC1107/slim-m/issues/843)) ([8f9b872](https://github.com/NC1107/slim-m/commit/8f9b872810f3575aca8760820ec8015f5a71c16e))


### Bug Fixes

* **server:** make invite redemption idempotent per user ([#721](https://github.com/NC1107/slim-m/issues/721)) ([8088d23](https://github.com/NC1107/slim-m/commit/8088d23f881a2c33e1c5affe41f1ca37474e31c4))
* **server:** publish unpin and thread update on message delete (MOD12) ([#731](https://github.com/NC1107/slim-m/issues/731)) ([0ed7a0f](https://github.com/NC1107/slim-m/commit/0ed7a0f1d5f7ade7f00f1453beb3b7726ce76080))


### Performance Improvements

* **server:** batch the message-retention prune ([#719](https://github.com/NC1107/slim-m/issues/719)) ([86a57d9](https://github.com/NC1107/slim-m/commit/86a57d9866cd042af5d63b955728419a8262966f))
* **server:** compute the reaction summary once per event (SRV1) ([#729](https://github.com/NC1107/slim-m/issues/729)) ([75d91b6](https://github.com/NC1107/slim-m/commit/75d91b6c98debbefb98c69d3cf7222438257ee3f))
* **server:** fan out the stale-voice-call sweep (SRV6) ([#761](https://github.com/NC1107/slim-m/issues/761)) ([6bd8a1d](https://github.com/NC1107/slim-m/commit/6bd8a1d951811651d5dbd00c9ad29137bb7d88e0))

## [0.43.0](https://github.com/NC1107/slim-m/compare/server-v0.42.0...server-v0.43.0) (2026-08-19)


### Features

* **server:** store and serve a message's edit history ([#716](https://github.com/NC1107/slim-m/issues/716)) ([54ad86c](https://github.com/NC1107/slim-m/commit/54ad86cd92ece1b2592dfc6bcd89e2dfec8b2bc6))
* **server:** stream attachments and support HTTP Range ([#711](https://github.com/NC1107/slim-m/issues/711)) ([e27e2ea](https://github.com/NC1107/slim-m/commit/e27e2eab7fffa95ff01ba3da9b3a20ead125c5cf))


### Performance Improvements

* **server:** batch the DM list's per-conversation queries ([#715](https://github.com/NC1107/slim-m/issues/715)) ([93d3aa5](https://github.com/NC1107/slim-m/commit/93d3aa531cb4825ebab92d4feb977dd49d7a831c))

## [0.42.0](https://github.com/NC1107/slim-m/compare/server-v0.41.0...server-v0.42.0) (2026-08-19)


### Features

* **server:** raise the default upload limit to 100 MiB ([#705](https://github.com/NC1107/slim-m/issues/705)) ([8c7db57](https://github.com/NC1107/slim-m/commit/8c7db57ca2f5fb8b6c9d8575ff904955fc6696ad))

## [0.41.0](https://github.com/NC1107/slim-m/compare/server-v0.40.0...server-v0.41.0) (2026-08-18)


### ⚠ BREAKING CHANGES

* **messages:** MANAGE_MESSAGES reaches every message, an administrator's too ([#677](https://github.com/NC1107/slim-m/issues/677))

### Features

* **messages:** delete several messages as one act ([#675](https://github.com/NC1107/slim-m/issues/675)) ([293f3e2](https://github.com/NC1107/slim-m/commit/293f3e2f90b05b3bac861bff05693efda183f309))
* **messages:** MANAGE_MESSAGES reaches every message, an administrator's too ([#677](https://github.com/NC1107/slim-m/issues/677)) ([b63d29e](https://github.com/NC1107/slim-m/commit/b63d29e1e11da6d2652bc62e4914f9cfad5b9d3e))

## [0.40.0](https://github.com/NC1107/slim-m/compare/server-v0.39.1...server-v0.40.0) (2026-08-15)


### Features

* **moderation:** keep a record of a removal or timeout after it is undone ([#670](https://github.com/NC1107/slim-m/issues/670)) ([4b8b96c](https://github.com/NC1107/slim-m/commit/4b8b96c42b2d6089710a0fc875534d91f829b1ce))

## [0.39.1](https://github.com/NC1107/slim-m/compare/server-v0.39.0...server-v0.39.1) (2026-08-14)


### Performance Improvements

* **db:** index the four account-deletion and role-member scans ([#663](https://github.com/NC1107/slim-m/issues/663)) ([921e97e](https://github.com/NC1107/slim-m/commit/921e97efb7a34a09ef1ae87aef68730c71492e31))

## [0.39.0](https://github.com/NC1107/slim-m/compare/server-v0.38.0...server-v0.39.0) (2026-08-14)


### Features

* **client,server:** forward a message, mass mentions, and a status line ([#645](https://github.com/NC1107/slim-m/issues/645)) ([3da6f6c](https://github.com/NC1107/slim-m/commit/3da6f6c770b7e6b0808384fe49512d0ebfff458a))
* four thread gaps closed - listing, unread state, a cross-link, and a cap ([#634](https://github.com/NC1107/slim-m/issues/634)) ([4905df3](https://github.com/NC1107/slim-m/commit/4905df3fed131691617a525542d2bfbb12dacd4f))
* GIF search in the composer, proxied through the server ([#639](https://github.com/NC1107/slim-m/issues/639)) ([e2573a6](https://github.com/NC1107/slim-m/commit/e2573a624be1a7475a34eb1f1b7c258b21522543))
* mute a channel, or narrow it to mentions only ([#643](https://github.com/NC1107/slim-m/issues/643)) ([ea855c3](https://github.com/NC1107/slim-m/commit/ea855c35238c8e3fd0947d5e088678c19a630cdf))
* **search:** Slack-style search operators (from:, in:, has:, before:/after:) ([#638](https://github.com/NC1107/slim-m/issues/638)) ([bf2aa7c](https://github.com/NC1107/slim-m/commit/bf2aa7cd29205f98f285c86c91d87f9c2d436028))
* **server:** add GET /metrics and a real livekit healthcheck ([#632](https://github.com/NC1107/slim-m/issues/632)) ([b89c8b2](https://github.com/NC1107/slim-m/commit/b89c8b23897d3daaf07130525243bb41a158f0cd))
* **server:** per-member attachment storage and message retention ([#633](https://github.com/NC1107/slim-m/issues/633)) ([b70fced](https://github.com/NC1107/slim-m/commit/b70fced88cf99778194efae88d049754f4ebb049))


### Bug Fixes

* **push:** stamp sent_at inside the sealed envelope and refuse stale previews ([#631](https://github.com/NC1107/slim-m/issues/631)) ([436f0ba](https://github.com/NC1107/slim-m/commit/436f0baa2d9b43af0af998d52f53fb8068da4cdb))
* **server:** renumber the notification-prefs migration off a collision ([#647](https://github.com/NC1107/slim-m/issues/647)) ([202f849](https://github.com/NC1107/slim-m/commit/202f849ea17cee853c0f2051ce32d4b3c4ec49d1))

## [0.38.0](https://github.com/NC1107/slim-m/compare/server-v0.37.0...server-v0.38.0) (2026-08-12)


### Features

* **server:** a restored member reaches connected clients ([#602](https://github.com/NC1107/slim-m/issues/602)) ([0068eec](https://github.com/NC1107/slim-m/commit/0068eec4c9eeca02d26c21853ed02a23c20d9fc8))


### Bug Fixes

* an empty push preview, and two report columns deletion never cleared ([#584](https://github.com/NC1107/slim-m/issues/584)) ([550d9b0](https://github.com/NC1107/slim-m/commit/550d9b028d5c21a88256907e66ba5a0d11bc621c))
* **server:** a thread could be renamed, and could not be deleted ([#589](https://github.com/NC1107/slim-m/issues/589)) ([06de9d3](https://github.com/NC1107/slim-m/commit/06de9d3f6b9ea5926af8615206ea08c6fde33f5e))
* **server:** anonymize the three authorship columns deletion missed ([#598](https://github.com/NC1107/slim-m/issues/598)) ([2683152](https://github.com/NC1107/slim-m/commit/2683152b57abe30e968bf635fe543452b5e97470))
* **server:** charge a rate limit on every authenticated read ([#583](https://github.com/NC1107/slim-m/issues/583)) ([ae60108](https://github.com/NC1107/slim-m/commit/ae6010875749fd34da9bbb44604da1be444ca29e))
* **server:** end a deleted channel's call, rather than leaving it running ([#581](https://github.com/NC1107/slim-m/issues/581)) ([66dfbbb](https://github.com/NC1107/slim-m/commit/66dfbbb117af032f321aff7fbaafcf48d0110304))
* **server:** keep a duplicate sync scope's op cursor, and harden two review-flagged tests ([#604](https://github.com/NC1107/slim-m/issues/604)) ([641202e](https://github.com/NC1107/slim-m/commit/641202ec50b8bef04d6123b5efa49f41414be51a))
* **server:** the report queue leaked a channel a moderator could not see ([#582](https://github.com/NC1107/slim-m/issues/582)) ([2fce7b0](https://github.com/NC1107/slim-m/commit/2fce7b0af104d44c33bc1daf0c3e6739a7ea5bdd))


### Performance Improvements

* **server:** fix the review's two critical query findings ([#597](https://github.com/NC1107/slim-m/issues/597)) ([6b96605](https://github.com/NC1107/slim-m/commit/6b9660521975111948cc69566212a2b6b34e7fab))
* **server:** single-pass analytics buckets, batched canvas ops and attachment checks, thread-parent index ([#601](https://github.com/NC1107/slim-m/issues/601)) ([d7b6fd5](https://github.com/NC1107/slim-m/commit/d7b6fd51fd15ea42d5c018c8eb7c084b5c688172))

## [0.37.0](https://github.com/NC1107/slim-m/compare/server-v0.36.0...server-v0.37.0) (2026-08-11)


### Features

* **client:** decrypt the sealed push preview on a locked iPhone ([#574](https://github.com/NC1107/slim-m/issues/574)) ([9a7ef9e](https://github.com/NC1107/slim-m/commit/9a7ef9e373e9f7854b62276f3a948f1013535229))

## [0.36.0](https://github.com/NC1107/slim-m/compare/server-v0.35.1...server-v0.36.0) (2026-08-11)


### Features

* **server:** seal an optional message preview inside the push envelope ([#569](https://github.com/NC1107/slim-m/issues/569)) ([1084f00](https://github.com/NC1107/slim-m/commit/1084f00cb55e638703ec31eef873c99a2b7ae5f5))

## [0.35.1](https://github.com/NC1107/slim-m/compare/server-v0.35.0...server-v0.35.1) (2026-08-11)


### Bug Fixes

* **ci:** close comment-defeatable blind spots in source-reading gates ([#553](https://github.com/NC1107/slim-m/issues/553)) ([1b13496](https://github.com/NC1107/slim-m/commit/1b1349601f63a6b6694c2de1539e5171337eae50))
* **client:** close the second-tier findings from the screen-review pass ([#542](https://github.com/NC1107/slim-m/issues/542)) ([2275fe9](https://github.com/NC1107/slim-m/commit/2275fe9d522d947f970e708ebb7cc28dce0e734d))
* **client:** close the sharp findings from the screen-review pass ([#535](https://github.com/NC1107/slim-m/issues/535)) ([f5b1d13](https://github.com/NC1107/slim-m/commit/f5b1d13fa06c02b89daabc726f83146cdf676a0f))

## [0.35.0](https://github.com/NC1107/slim-m/compare/server-v0.34.0...server-v0.35.0) (2026-08-10)


### Features

* **server:** add GET /channels/{channel_id}/permissions ([#518](https://github.com/NC1107/slim-m/issues/518)) ([e84431c](https://github.com/NC1107/slim-m/commit/e84431c8af823913b285aa48b46ca8aabf0d554d))
* **server:** carry the caller's permissions onto listChannels and listOpenReports ([#520](https://github.com/NC1107/slim-m/issues/520)) ([823ea67](https://github.com/NC1107/slim-m/commit/823ea674b060767c2112503ddc4ef1323d902c03))

## [0.34.0](https://github.com/NC1107/slim-m/compare/server-v0.33.2...server-v0.34.0) (2026-08-09)


### Features

* **canvas:** media tile placement is shared and persists between calls ([#471](https://github.com/NC1107/slim-m/issues/471)) ([a16267b](https://github.com/NC1107/slim-m/commit/a16267bb47cc7a7a6c2997f207619ce11f2fc738))


### Bug Fixes

* **canvas:** the server never enforced a media tile's lock ([#476](https://github.com/NC1107/slim-m/issues/476)) ([5e39f21](https://github.com/NC1107/slim-m/commit/5e39f21d57dae8f0336dffdfe2cae0afc517c1c7))

## [0.33.2](https://github.com/NC1107/slim-m/compare/server-v0.33.1...server-v0.33.2) (2026-08-06)


### Bug Fixes

* **canvas:** a spent remove op could be replayed to undo somebody else's moderation ([#450](https://github.com/NC1107/slim-m/issues/450)) ([c15e82f](https://github.com/NC1107/slim-m/commit/c15e82f94bd28c99cfd177d363e66c2c07915b25))
* **canvas:** index the two columns the sweep and the op clock scan the whole table for ([#454](https://github.com/NC1107/slim-m/issues/454)) ([4ab71ca](https://github.com/NC1107/slim-m/commit/4ab71ca686a1a16ea094ae621d8b0fe18d1dd5cb))
* **canvas:** seed the op clock from the database, so a restart cannot reopen a closed bypass ([#451](https://github.com/NC1107/slim-m/issues/451)) ([1e51e65](https://github.com/NC1107/slim-m/commit/1e51e655c56e3a392e5067bae9239795493d6de1))

## [0.33.1](https://github.com/NC1107/slim-m/compare/server-v0.33.0...server-v0.33.1) (2026-08-06)


### Bug Fixes

* **canvas:** a clear that wrote rows it never reads, and a millisecond two writes can share ([#448](https://github.com/NC1107/slim-m/issues/448)) ([2a8e5ed](https://github.com/NC1107/slim-m/commit/2a8e5ed829c70fb3f6eee8743883897312eb9006))
* **canvas:** cap an in-flight draft, and measure a note in the bytes the wire actually counts ([#438](https://github.com/NC1107/slim-m/issues/438)) ([8279d8f](https://github.com/NC1107/slim-m/commit/8279d8f9aca6abd9b0f4971598fe6ab872f10955))
* **canvas:** count a restore's own targets against the op feed's byte budget ([#445](https://github.com/NC1107/slim-m/issues/445)) ([687b959](https://github.com/NC1107/slim-m/commit/687b95975188972102882b386bde5819c46a3cd5))

## [0.33.0](https://github.com/NC1107/slim-m/compare/server-v0.32.0...server-v0.33.0) (2026-08-06)


### Features

* **canvas:** compact the op log, and keep a moderation trail that outlives it ([#433](https://github.com/NC1107/slim-m/issues/433)) ([2eb9a10](https://github.com/NC1107/slim-m/commit/2eb9a109030a9db9dae4074ee358fa22a3a4562d))
* **canvas:** the note and shape tools decision 0004 named ([#435](https://github.com/NC1107/slim-m/issues/435)) ([bd532de](https://github.com/NC1107/slim-m/commit/bd532de88f3a9d2416f3f8519614a302f9e15e18))
* **canvas:** watch somebody draw, rather than watching their stroke appear ([#434](https://github.com/NC1107/slim-m/issues/434)) ([5024ab0](https://github.com/NC1107/slim-m/commit/5024ab03f4380777e8513b64d639248aa8532300))


### Bug Fixes

* **canvas:** re-check MANAGE_CANVAS when restoring another's moderation ([#429](https://github.com/NC1107/slim-m/issues/429)) ([18dafd2](https://github.com/NC1107/slim-m/commit/18dafd2ea49ae16a00fa9461d5f475a36fd7d0cd))

## [0.32.0](https://github.com/NC1107/slim-m/compare/server-v0.31.0...server-v0.32.0) (2026-08-05)


### Features

* **canvas:** resize a placed image, and control what sits on top ([#416](https://github.com/NC1107/slim-m/issues/416)) ([8d388f8](https://github.com/NC1107/slim-m/commit/8d388f88eaff6b1d646e90297f7ded5d885347de))
* paste an image onto the canvas and drag it around ([#410](https://github.com/NC1107/slim-m/issues/410)) ([b07e263](https://github.com/NC1107/slim-m/commit/b07e2637e7259091ba1b8e65ce01dabe616217a4))

## [0.31.0](https://github.com/NC1107/slim-m/compare/server-v0.30.0...server-v0.31.0) (2026-08-05)


### Features

* a per-account notification preference, including mentions only ([#397](https://github.com/NC1107/slim-m/issues/397)) ([9c756f8](https://github.com/NC1107/slim-m/commit/9c756f8fb5c003af1792fe8706cbf52e8635f2a5))
* multi-user canvas cursors, live and ephemeral ([#400](https://github.com/NC1107/slim-m/issues/400)) ([b4f6b8c](https://github.com/NC1107/slim-m/commit/b4f6b8cc75601cc0c88224c01a50e78a6370dcfb))
* Space usage analytics, off by default ([#401](https://github.com/NC1107/slim-m/issues/401)) ([f140ca8](https://github.com/NC1107/slim-m/commit/f140ca8154607fe27c68e4e22d7828d3123660a0))

## [0.30.0](https://github.com/NC1107/slim-m/compare/server-v0.29.0...server-v0.30.0) (2026-08-04)


### Features

* **server:** accept video, audio, archives and text as attachments ([#378](https://github.com/NC1107/slim-m/issues/378)) ([76a68bd](https://github.com/NC1107/slim-m/commit/76a68bd82f8939f9ac498bdd271af3fd7a98cd60))


### Bug Fixes

* widen the mention charset to match what a username can be ([#374](https://github.com/NC1107/slim-m/issues/374)) ([901e712](https://github.com/NC1107/slim-m/commit/901e712e54788f75a3a066c08a2844c126bf6ad9))

## [0.29.0](https://github.com/NC1107/slim-m/compare/server-v0.28.0...server-v0.29.0) (2026-08-04)


### Features

* a live in-app signal when a DM call starts or ends ([#358](https://github.com/NC1107/slim-m/issues/358)) ([4f34b57](https://github.com/NC1107/slim-m/commit/4f34b577a86ef69a7238df3160314784723154f2))


### Bug Fixes

* a thread reply wakes the thread, not the whole parent channel ([#357](https://github.com/NC1107/slim-m/issues/357)) ([ebc3d47](https://github.com/NC1107/slim-m/commit/ebc3d47caf0d1dd0e8b1bcf482b259a58ae9d4ed))
* eight findings from the 2026-08-04 multi-agent audit ([#362](https://github.com/NC1107/slim-m/issues/362)) ([2d954d3](https://github.com/NC1107/slim-m/commit/2d954d3453ec156382cdf33df4c822e2081cee71))

## [0.28.0](https://github.com/NC1107/slim-m/compare/server-v0.27.1...server-v0.28.0) (2026-08-04)


### Features

* channel categories you can drag any channel into ([#355](https://github.com/NC1107/slim-m/issues/355)) ([b34cd78](https://github.com/NC1107/slim-m/commit/b34cd786656c10d9b6de150f947642cdb81ceb53))


### Bug Fixes

* **client:** name why a message failed to send, and refuse it before it does ([#345](https://github.com/NC1107/slim-m/issues/345)) ([e20e9ab](https://github.com/NC1107/slim-m/commit/e20e9ab922f8eb20889cb1aaff4ffb0fddcf13e8))

## [0.27.1](https://github.com/NC1107/slim-m/compare/server-v0.27.0...server-v0.27.1) (2026-08-03)


### Bug Fixes

* moderation and blocking reach DM calls and thread reports ([#336](https://github.com/NC1107/slim-m/issues/336)) ([968bdfe](https://github.com/NC1107/slim-m/commit/968bdfe801daadff08c233f79d8d520c412ea4cc))

## [0.27.0](https://github.com/NC1107/slim-m/compare/server-v0.26.0...server-v0.27.0) (2026-08-03)


### Features

* live signal for a thread opening or gaining a reply ([#329](https://github.com/NC1107/slim-m/issues/329)) ([2fe2c9f](https://github.com/NC1107/slim-m/commit/2fe2c9ff3084701575bbacf41c27f27ae81d2e88))

## [0.26.0](https://github.com/NC1107/slim-m/compare/server-v0.25.0...server-v0.26.0) (2026-08-02)


### Features

* a reply-count affordance on threaded messages ([#315](https://github.com/NC1107/slim-m/issues/315)) ([a5d0524](https://github.com/NC1107/slim-m/commit/a5d05245162cdd5decacde3d487dd13e5053c955))

## [0.25.0](https://github.com/NC1107/slim-m/compare/server-v0.24.0...server-v0.25.0) (2026-08-01)


### Features

* threads, a channel with a parent (docs/decisions/0005-threads.md) ([#312](https://github.com/NC1107/slim-m/issues/312)) ([dc5e624](https://github.com/NC1107/slim-m/commit/dc5e624b496c8a4c5cd4d39a0c4758791ac6f61f))

## [0.24.0](https://github.com/NC1107/slim-m/compare/server-v0.23.0...server-v0.24.0) (2026-08-01)


### Features

* calling in a DM ([#306](https://github.com/NC1107/slim-m/issues/306)) ([6823474](https://github.com/NC1107/slim-m/commit/68234746807e080edb7f5e0b0ee4ebb2ecf95115))
* reply to a message, and write up threads instead of building them ([#308](https://github.com/NC1107/slim-m/issues/308)) ([dffcdaa](https://github.com/NC1107/slim-m/commit/dffcdaa1747eae05e61c858c6dcc17380fe990d8))


### Bug Fixes

* reconcile a display name across already-cached messages ([#288](https://github.com/NC1107/slim-m/issues/288)) ([7ed4906](https://github.com/NC1107/slim-m/commit/7ed4906fd6aa4e3c0c4cda81f1a315e2917ce2b1))

## [0.23.0](https://github.com/NC1107/slim-m/compare/server-v0.22.0...server-v0.23.0) (2026-08-01)


### Features

* drag to reorder channels, ordered deployment-wide ([#271](https://github.com/NC1107/slim-m/issues/271)) ([753b3d4](https://github.com/NC1107/slim-m/commit/753b3d4521908186ffe811dda712993fe20ed1aa))


### Bug Fixes

* **test:** stop the attachment fixture leaking a media directory per test ([#263](https://github.com/NC1107/slim-m/issues/263)) ([e5e6a5f](https://github.com/NC1107/slim-m/commit/e5e6a5f66153b7551b351074ca88d97677671bed))

## [0.22.0](https://github.com/NC1107/slim-m/compare/server-v0.21.0...server-v0.22.0) (2026-08-01)


### Features

* **client:** device-use polish, a what's-new screen, and a dead-code sweep ([#256](https://github.com/NC1107/slim-m/issues/256)) ([cd927ac](https://github.com/NC1107/slim-m/commit/cd927ac993bdaca37a5ccc31041e6f44009f46cd))

## [0.21.0](https://github.com/NC1107/slim-m/compare/server-v0.20.0...server-v0.21.0) (2026-07-31)


### Features

* **server:** a message op stream for edits and deletes ([#235](https://github.com/NC1107/slim-m/issues/235)) ([b686736](https://github.com/NC1107/slim-m/commit/b68673696f196440296075554f6e40f2b981ae02))
* **server:** carry message ops on /sync and the two live frames ([#237](https://github.com/NC1107/slim-m/issues/237)) ([16ecb5f](https://github.com/NC1107/slim-m/commit/16ecb5f369b94292237ffb3edc8e845a249cfd04))


### Bug Fixes

* **server:** withhold the canvas moderator's id from the ops feed ([#233](https://github.com/NC1107/slim-m/issues/233)) ([e2e9063](https://github.com/NC1107/slim-m/commit/e2e9063cb697b0167578af93039a4c7dd93d2655))

## [0.20.0](https://github.com/NC1107/slim-m/compare/server-v0.19.0...server-v0.20.0) (2026-07-31)


### Features

* **server:** canvas remove and clear, MANAGE_CANVAS enforcement, and the two new socket events ([#219](https://github.com/NC1107/slim-m/issues/219)) ([1ba6846](https://github.com/NC1107/slim-m/commit/1ba6846177436ad98fd2c28e470f8630f91b7b68))
* **server:** canvas restore, its authorship gate, and the object ceiling ([#221](https://github.com/NC1107/slim-m/issues/221)) ([f847baa](https://github.com/NC1107/slim-m/commit/f847baa9cb0efc586cdb8e92df33b4962892c272))

## [0.19.0](https://github.com/NC1107/slim-m/compare/server-v0.18.5...server-v0.19.0) (2026-07-31)


### Features

* a personal space, opened by DMing yourself ([#204](https://github.com/NC1107/slim-m/issues/204)) ([951d1b3](https://github.com/NC1107/slim-m/commit/951d1b341ebc3e7c1985211407ec05e9ce44e1f1))
* **server:** the canvas op stream, its catch-up feed, and one snapshot for the viewport read ([#218](https://github.com/NC1107/slim-m/issues/218)) ([ba79c07](https://github.com/NC1107/slim-m/commit/ba79c07107fab29b0de531ae116dd7d4ecdd2e9c))


### Bug Fixes

* a relaunched client no longer shows itself as still on a call ([#205](https://github.com/NC1107/slim-m/issues/205)) ([2aa141d](https://github.com/NC1107/slim-m/commit/2aa141dafc3861be4cdae859a5c95237fdb8bde7))
* **server:** four correctness findings in fan-out, presence, devices and member count ([#210](https://github.com/NC1107/slim-m/issues/210)) ([dbe65c3](https://github.com/NC1107/slim-m/commit/dbe65c3abe00b0eaca25fe7b49d0df312e9f9c8e))

## [0.18.5](https://github.com/NC1107/slim-m/compare/server-v0.18.4...server-v0.18.5) (2026-07-31)


### Bug Fixes

* **canvas:** a web z-index truncation, an unbounded refetch loop, and stacked headers ([#198](https://github.com/NC1107/slim-m/issues/198)) ([5875cc4](https://github.com/NC1107/slim-m/commit/5875cc4d57e999dc5b9364204c829d2139a2be6d))

## [0.18.4](https://github.com/NC1107/slim-m/compare/server-v0.18.3...server-v0.18.4) (2026-07-30)


### Bug Fixes

* **server:** make the typing presence gate fail closed on a store error ([#184](https://github.com/NC1107/slim-m/issues/184)) ([9eb1824](https://github.com/NC1107/slim-m/commit/9eb1824e336cbe7c17f0073ac20cc93b97636a9e))
* **server:** rebuild messages onto an explicit rowid alias ([#183](https://github.com/NC1107/slim-m/issues/183)) ([adc009a](https://github.com/NC1107/slim-m/commit/adc009a8252203a9a38fec4fb340560699ebb276))

## [0.18.3](https://github.com/NC1107/slim-m/compare/server-v0.18.2...server-v0.18.3) (2026-07-30)


### Bug Fixes

* **server:** answer a retried poll send after its message was deleted ([#174](https://github.com/NC1107/slim-m/issues/174)) ([b0d3892](https://github.com/NC1107/slim-m/commit/b0d3892b2d00d58c4e2f2b8b9b8e08623fcd05d7))
* **server:** make password recovery revoke sessions atomically ([#178](https://github.com/NC1107/slim-m/issues/178)) ([f2d73e7](https://github.com/NC1107/slim-m/commit/f2d73e7e0434bcf1f09529c13af082a0ffcf4438))

## [0.18.2](https://github.com/NC1107/slim-m/compare/server-v0.18.1...server-v0.18.2) (2026-07-30)


### Performance Improvements

* **ws:** cache VIEW_CHANNEL per connection, invalidated by the events ([#165](https://github.com/NC1107/slim-m/issues/165)) ([f794765](https://github.com/NC1107/slim-m/commit/f794765d61863a6814d1af26d2e287138de7b41b))

## [0.18.1](https://github.com/NC1107/slim-m/compare/server-v0.18.0...server-v0.18.1) (2026-07-30)


### Bug Fixes

* bound the two reads that answered with everything ([#148](https://github.com/NC1107/slim-m/issues/148)) ([eb352cd](https://github.com/NC1107/slim-m/commit/eb352cd26a3c2578c14b0d9685442650b0f28f5d))
* make blocking actually hide what it says it hides ([#147](https://github.com/NC1107/slim-m/issues/147)) ([7cf0618](https://github.com/NC1107/slim-m/commit/7cf0618b2f5b1ee4cda59b2df62a0c01611a1338))
* name the subject of a report before asking to close it ([#157](https://github.com/NC1107/slim-m/issues/157)) ([4546722](https://github.com/NC1107/slim-m/commit/45467221e564cf122e3dc8a90ce4f1852e92f27f))
* **server:** apply the target-level guard to role and voice moderation ([#149](https://github.com/NC1107/slim-m/issues/149)) ([316744a](https://github.com/NC1107/slim-m/commit/316744a61cf3e6017e9e1807e46f825a892c20e0))
* **server:** authorize an attachment reference, not just its existence ([#150](https://github.com/NC1107/slim-m/issues/150)) ([3b19c60](https://github.com/NC1107/slim-m/commit/3b19c602e24b0cea80a42e867ff430344798c708))
* **server:** bound the unauthenticated request surface ([#145](https://github.com/NC1107/slim-m/issues/145)) ([db5bbe7](https://github.com/NC1107/slim-m/commit/db5bbe70fd17253e04a57c0791be080bac1ef2ee))
* **server:** publish the role, overwrite and channel events nothing published ([#161](https://github.com/NC1107/slim-m/issues/161)) ([bef83ee](https://github.com/NC1107/slim-m/commit/bef83ee1411fd6e97f365f8d688878a2ecf28b97))
* **server:** set the two ceilings nobody had set ([#151](https://github.com/NC1107/slim-m/issues/151)) ([3649000](https://github.com/NC1107/slim-m/commit/3649000510e3ccf39b5f434c19ce9d3b20727bbf))

## [0.18.0](https://github.com/NC1107/slim-m/compare/server-v0.17.0...server-v0.18.0) (2026-07-29)


### Features

* **client:** per-participant volume, roles, timeout and removal in the member profile ([#138](https://github.com/NC1107/slim-m/issues/138)) ([e746bcd](https://github.com/NC1107/slim-m/commit/e746bcd4c89e1dcd507d49c43ea345d6ea4d83d5))
* **server:** member timeouts and removal from the Space ([#136](https://github.com/NC1107/slim-m/issues/136)) ([1474ef8](https://github.com/NC1107/slim-m/commit/1474ef89921907bdb1cbf20082249a1a07d11733))

## [0.17.0](https://github.com/NC1107/slim-m/compare/server-v0.16.1...server-v0.17.0) (2026-07-29)


### Features

* render peer screen shares, call tiles, and the nine-specialist audit batch ([#123](https://github.com/NC1107/slim-m/issues/123)) ([b34be33](https://github.com/NC1107/slim-m/commit/b34be33bc6b87f68995479f39a440e841cf18170))

## [0.16.1](https://github.com/NC1107/slim-m/compare/server-v0.16.0...server-v0.16.1) (2026-07-29)


### Bug Fixes

* close 16 defects a multi-agent audit found, moderation-queue holes first ([#118](https://github.com/NC1107/slim-m/issues/118)) ([b4eab36](https://github.com/NC1107/slim-m/commit/b4eab36e4e0b2b35a180542fe987225677fd82d7))

## [0.16.0](https://github.com/NC1107/slim-m/compare/server-v0.15.0...server-v0.16.0) (2026-07-28)


### Features

* add a per-channel voice roster so the rail shows who is already there ([#98](https://github.com/NC1107/slim-m/issues/98)) ([06d13d7](https://github.com/NC1107/slim-m/commit/06d13d7b3c96cc5b137a8131fd1da870cc4785b6))


### Bug Fixes

* **server:** map malformed-body and query rejections to the JSON error contract ([#102](https://github.com/NC1107/slim-m/issues/102)) ([0d06318](https://github.com/NC1107/slim-m/commit/0d063189845c7f20ca48b5857cc911d847b01c36))

## [0.15.0](https://github.com/NC1107/slim-m/compare/server-v0.14.3...server-v0.15.0) (2026-07-28)


### Features

* role-granting invites, a disabled segmented option, and a backlog that was mostly stale ([#87](https://github.com/NC1107/slim-m/issues/87)) ([25b10fb](https://github.com/NC1107/slim-m/commit/25b10fb671e26ecfe5e8d62daa5f1aeafae832a3))


### Bug Fixes

* **server:** carry a message's attachments on its live frame ([#91](https://github.com/NC1107/slim-m/issues/91)) ([7c1a626](https://github.com/NC1107/slim-m/commit/7c1a626638e047cac7f1bdfd19aa81701fb2d319))

## [0.14.3](https://github.com/NC1107/slim-m/compare/server-v0.14.2...server-v0.14.3) (2026-07-28)


### Bug Fixes

* **server:** deleting a message whose image is also an emoji ([#85](https://github.com/NC1107/slim-m/issues/85)) ([2d2644b](https://github.com/NC1107/slim-m/commit/2d2644ba4ea902f0752ba40b06995e4f248e97cf))

## [0.14.2](https://github.com/NC1107/slim-m/compare/server-v0.14.1...server-v0.14.2) (2026-07-28)


### Bug Fixes

* desktop screen share, colour emoji, rail alignment, and who can join ([#81](https://github.com/NC1107/slim-m/issues/81)) ([4dd1bb1](https://github.com/NC1107/slim-m/commit/4dd1bb13090f2056952743ea397073df4bdb5ba3))

## [0.14.1](https://github.com/NC1107/slim-m/compare/server-v0.14.0...server-v0.14.1) (2026-07-28)


### Bug Fixes

* **mobile:** image-only sends, fullscreen media, Fedora packaging, and Space naming ([#77](https://github.com/NC1107/slim-m/issues/77)) ([cbf89d4](https://github.com/NC1107/slim-m/commit/cbf89d494fb80e7f14a01677237358eda5c9bbe2))

## [0.14.0](https://github.com/NC1107/slim-m/compare/server-v0.13.0...server-v0.14.0) (2026-07-27)


### Features

* **server:** bulk emoji import, and fix the orphan sweep it exposed ([#75](https://github.com/NC1107/slim-m/issues/75)) ([4e3e9b1](https://github.com/NC1107/slim-m/commit/4e3e9b11931e591caee1129622771cdbbd861b81))
* **server:** custom emoji ([#72](https://github.com/NC1107/slim-m/issues/72)) ([4823ef7](https://github.com/NC1107/slim-m/commit/4823ef7f4415efb5ad92ea81ad3d0138fef245b9))

## [0.13.0](https://github.com/NC1107/slim-m/compare/server-v0.12.0...server-v0.13.0) (2026-07-27)


### Features

* CORS, moderation and admin UI, message actions, and a web build ([#61](https://github.com/NC1107/slim-m/issues/61)) ([dca58e6](https://github.com/NC1107/slim-m/commit/dca58e690dc66ee5c049e60513982452e042f65e))

## [0.12.0](https://github.com/NC1107/slim-m/compare/server-v0.11.1...server-v0.12.0) (2026-07-27)


### Features

* the Phase 5 canvas de-risking spike ([#59](https://github.com/NC1107/slim-m/issues/59)) ([614aba0](https://github.com/NC1107/slim-m/commit/614aba096348a38662c5bb4c85b9088733c3bde8))

## [0.11.1](https://github.com/NC1107/slim-m/compare/server-v0.11.0...server-v0.11.1) (2026-07-27)


### Bug Fixes

* iOS purpose strings, the Android Kotlin build, and the voice kick ([#55](https://github.com/NC1107/slim-m/issues/55)) ([c7980f2](https://github.com/NC1107/slim-m/commit/c7980f2591e7be93cd9d2da2bdbd71bc9e84014a))

## [0.11.0](https://github.com/NC1107/slim-m/compare/server-v0.10.0...server-v0.11.0) (2026-07-26)


### Features

* align the ui to the design, and build the backends it assumed ([#52](https://github.com/NC1107/slim-m/issues/52)) ([fdc56a8](https://github.com/NC1107/slim-m/commit/fdc56a8067f580e3d8c6a9ba22193cd5e2ecb64e))

## [0.10.0](https://github.com/NC1107/slim-m/compare/server-v0.9.0...server-v0.10.0) (2026-07-26)


### Features

* phase 4 rtc spike, livekit tokens, callkit, and the design review ([#47](https://github.com/NC1107/slim-m/issues/47)) ([719331b](https://github.com/NC1107/slim-m/commit/719331b9d069aa1dcdebce7d123838c6624419ff))

## [0.9.0](https://github.com/NC1107/slim-m/compare/server-v0.8.0...server-v0.9.0) (2026-07-26)


### ⚠ BREAKING CHANGES

* gate registration behind an invite, plus the phase 3 audit fixes ([#42](https://github.com/NC1107/slim-m/issues/42))

### Features

* gate registration behind an invite, plus the phase 3 audit fixes ([#42](https://github.com/NC1107/slim-m/issues/42)) ([06a9397](https://github.com/NC1107/slim-m/commit/06a93975f126f39aec335760ba0712901103b279))

## [0.8.0](https://github.com/NC1107/slim-m/compare/server-v0.7.0...server-v0.8.0) (2026-07-26)


### Features

* surface push reachability during onboarding ([#39](https://github.com/NC1107/slim-m/issues/39)) ([76e4cfd](https://github.com/NC1107/slim-m/commit/76e4cfddf35a86bb678930cf9f850e2f34493f26))

## [0.7.0](https://github.com/NC1107/slim-m/compare/server-v0.6.0...server-v0.7.0) (2026-07-26)


### Features

* android push, sender names, and the envelope contract test ([#33](https://github.com/NC1107/slim-m/issues/33)) ([e689871](https://github.com/NC1107/slim-m/commit/e6898716143160e1c5a3ebc96311d6f094453025))
* **server:** the endpoints the frontend still needs ([#36](https://github.com/NC1107/slim-m/issues/36)) ([a2011fc](https://github.com/NC1107/slim-m/commit/a2011fc8802080992a8f0260968f05f7bd63124c))

## [0.6.0](https://github.com/NC1107/slim-m/compare/server-v0.5.0...server-v0.6.0) (2026-07-25)


### Features

* server-side push, mobile targets, and the TestFlight pipeline ([#30](https://github.com/NC1107/slim-m/issues/30)) ([9799f9d](https://github.com/NC1107/slim-m/commit/9799f9d5a5e82a9699da00b974a2a18c760a0c99))
* **server:** devices, blocking, and report intake ([#24](https://github.com/NC1107/slim-m/issues/24)) ([5046e04](https://github.com/NC1107/slim-m/commit/5046e04c02459b4507ee611397852c770f656b73))
* **server:** invites ([#27](https://github.com/NC1107/slim-m/issues/27)) ([29960a8](https://github.com/NC1107/slim-m/commit/29960a81454fe1afd320a5fca31897dd8916582e))

## [0.5.0](https://github.com/NC1107/slim-m/compare/server-v0.4.0...server-v0.5.0) (2026-07-24)


### Features

* **server:** in-process rate limiting ([#19](https://github.com/NC1107/slim-m/issues/19)) ([7003f46](https://github.com/NC1107/slim-m/commit/7003f46076a30cbc0d09023b5fda2aada11bc7c8))

## [0.4.0](https://github.com/NC1107/slim-m/compare/server-v0.3.0...server-v0.4.0) (2026-07-24)


### Features

* **server:** first-run bootstrap and channel routes ([#16](https://github.com/NC1107/slim-m/issues/16)) ([0dbd743](https://github.com/NC1107/slim-m/commit/0dbd743ca3f5d7419271463d602dcaaa1e991095))

## [0.3.0](https://github.com/NC1107/slim-m/compare/server-v0.2.0...server-v0.3.0) (2026-07-24)


### Features

* complete Phase 0 build-out (CI, release pipeline, perf, gates, compose) ([62bf042](https://github.com/NC1107/slim-m/commit/62bf042a47865f7216416fd54275a6bf14f997b5))
* **db:** add Phase 1 core schema migration ([#3](https://github.com/NC1107/slim-m/issues/3)) ([a35e59f](https://github.com/NC1107/slim-m/commit/a35e59f1f7a7e9189581ab3794489220d0609dc7))
* scaffold Phase 0 foundations ([e7f3028](https://github.com/NC1107/slim-m/commit/e7f3028d2620788f414db953cde2c84db8c07589))
* **server:** account deletion end to end ([#15](https://github.com/NC1107/slim-m/issues/15)) ([cb16f8d](https://github.com/NC1107/slim-m/commit/cb16f8d81073bfa2ff54858ed35329b468b8bc22))
* **server:** auth with Argon2id, opaque tokens, refresh rotation, and WS tickets ([#10](https://github.com/NC1107/slim-m/issues/10)) ([36cf7bf](https://github.com/NC1107/slim-m/commit/36cf7bf1cb920b2d725dcbae1b9ac9881b3aa16a))
* **server:** deny-by-default permission evaluator ([#11](https://github.com/NC1107/slim-m/issues/11)) ([47e297a](https://github.com/NC1107/slim-m/commit/47e297acf0a1897c985ac6f6bc8fe36e22507326))
* **server:** identity and message store (per-scope ordering, idempotent send) ([#8](https://github.com/NC1107/slim-m/issues/8)) ([3e1f37d](https://github.com/NC1107/slim-m/commit/3e1f37d6de5702e2602f5cda13911239eb365cd1))
* **server:** read state and the bundled sync cursor ([#14](https://github.com/NC1107/slim-m/issues/14)) ([df726fc](https://github.com/NC1107/slim-m/commit/df726fc9eedfdabaf98b22a987491765e092e561))
* **server:** REST message endpoints with server-side authorization ([#12](https://github.com/NC1107/slim-m/issues/12)) ([a95063f](https://github.com/NC1107/slim-m/commit/a95063f3a5bd5ca5243b1e41fce7c6e3f5f4ae22))
* **server:** WebSocket envelope and fan-out ([#13](https://github.com/NC1107/slim-m/issues/13)) ([071536e](https://github.com/NC1107/slim-m/commit/071536e230053fd029d67bccf0f61eb0eb5274a9))

## [0.2.0](https://github.com/NC1107/slim-m/compare/server-v0.1.0...server-v0.2.0) (2026-07-24)


### Features

* complete Phase 0 build-out (CI, release pipeline, perf, gates, compose) ([62bf042](https://github.com/NC1107/slim-m/commit/62bf042a47865f7216416fd54275a6bf14f997b5))
* **db:** add Phase 1 core schema migration ([#3](https://github.com/NC1107/slim-m/issues/3)) ([a35e59f](https://github.com/NC1107/slim-m/commit/a35e59f1f7a7e9189581ab3794489220d0609dc7))
* scaffold Phase 0 foundations ([e7f3028](https://github.com/NC1107/slim-m/commit/e7f3028d2620788f414db953cde2c84db8c07589))

## 0.1.0 (2026-07-24)


### Features

* complete Phase 0 build-out (CI, release pipeline, perf, gates, compose) ([62bf042](https://github.com/NC1107/slim-m/commit/62bf042a47865f7216416fd54275a6bf14f997b5))
* **db:** add Phase 1 core schema migration ([#3](https://github.com/NC1107/slim-m/issues/3)) ([a35e59f](https://github.com/NC1107/slim-m/commit/a35e59f1f7a7e9189581ab3794489220d0609dc7))
* scaffold Phase 0 foundations ([e7f3028](https://github.com/NC1107/slim-m/commit/e7f3028d2620788f414db953cde2c84db8c07589))
