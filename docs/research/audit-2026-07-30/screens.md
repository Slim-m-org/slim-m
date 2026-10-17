<!-- SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0 -->
# Screens and experience

Eleven screens went through adversarial verification, and the split is clean: the member-facing screens are decent-to-fair, and the administration screens are the weak half.
Nothing member-facing is broken - onboarding, sign-in, the channel and the voice screens all do their jobs, and the design language is visible in them.
The admin screens are where the product stops being finished: three of the five cannot show the operator what they are acting on, one of those (the report queue) cannot be used for its stated purpose at all, and the shared modal frame they all sit in has a declared border that paints nothing and a fixed height that leaves most of the panel empty.
The recurring cause is not carelessness at the screen level.
It is that the design system's guarantees are opt-in at the call site, the snapshot gate renders states the server cannot produce while never rendering the states that break, and the error-grammar migration recorded as done is roughly half done.

## Ratings

| Screen | Rating | Why |
| --- | --- | --- |
| Channel (text) | Fair - the strongest here | Complete, coherent and the design language shows; its gaps are missing capabilities (history pagination, jump-to-present) plus a roster that silently truncates at 50. |
| Onboarding | Fair | No functional defect, but the desktop composition has nothing anchoring it, the stepper counts to three over two panes, and the three entry cards are a raw `InkWell`. |
| Voice | Fair | Proven end to end, and the polish is where it fails: a second divergent channel header, mute state lost the moment somebody shares, a pre-toggle that looks read-only. |
| Personal settings | Fair | The redesign is coherent, but drill-down is local state rather than a route, "Delete account" is filed under "About slim-m", and the Blocked pane lists raw UUIDs. |
| Space settings | Fair | Works and reads well, but it is a second settings design in the same panel, and its list is ragged against its own title at both widths, in opposite directions. |
| Sign-in | Weak | Account recovery has no UI at either end, autofill is never committed, and there is no password reveal - one typo at creation can lock a self-hosted account out permanently. |
| Admin: invites | Weak | A fully spent invite is labelled "Expired" directly above "10/10 uses · Never expires", an existing code cannot be copied or even selected, and the role an invite grants is never shown. |
| Admin: roles | Weak | A long role name is clipped mid-glyph under the action icons, "Assign" is offered on @everyone where it can never read back, and a disabled toggle is pixel-identical to a live one. |
| Admin: channel overwrites | Weak | Blind by construction (no read-back route exists), the destructive blind replace is unconfirmed while the strictly safer Clear gets a dialog, and the first of sixteen rows is inert. |
| Admin: emoji | Weak | You upload an image you never see, represented by a checkmark, and cannot unchoose it; the 1 MiB ceiling is neither stated nor checked before the upload. |
| Admin: reports | Bad | The report card names neither the reported user, the reporter, nor the channel, and offers no action on the content - a user report renders as two words, one sentence and a date. |

## 1. Screens that cannot show what they are acting on

This is the theme that produced the two highest-severity findings, and it was reached independently by five specialists.

**The report card identifies nobody** (high) - `client/packages/app/lib/src/features/settings/screens/admin/reports_screen.dart:97`.
`reporterId`, `subjectId` and `channelId` are all on the model and all served, and the screen reads none of them; a user report has no snapshot either, so nothing on screen names the account being judged.
The moderator is asked for an irreversible close on a subject they cannot name, and three members reporting one account renders identically to one member settling a grudge.
Shape: resolve the ids through the batch profile fetch that already exists and put the subject, reporter and channel at the top of the card.

**The emoji upload never shows the image** (high) - `client/packages/app/lib/src/screens/admin/emoji_upload_card.dart:156`.
`_bytes` is read only to swap a button label to "Image chosen" and to enable submit; nothing renders it, and a cancelled re-pick leaves the previous bytes in place with no way to clear them.
The product of the form is a picture drawn at 20pt, and the form represents it with a checkmark.
Shape: render the chosen bytes at the two sizes the app actually draws, plus a control that clears the choice.

**Channel overwrites cannot read back, and the GET is missing from the router only** (medium) - `crates/slimm-server/src/http/overwrites.rs:39`.
`Store::overwrite_for` exists and both existing routes already call it; only the route and its schema entry are absent.
Three other defects on that screen - the blind replace, the phantom Clear, the unexplainable 403 - are downstream of this one gap, and the screen's own callout states the limitation as a fact about the world rather than about the HTTP surface.
Shape: add the read route with its schema and contract-test entries, then hydrate the form from it.

**The Blocked pane lists raw user ids** (medium) - `client/packages/app/lib/src/features/settings/widgets/personal_account_sections.dart:130`.
A whole top-level settings category renders a column of UUIDs, so its only purpose - unblocking a specific person - requires guessing.

**An invite's role grant is on the wire and never shown** (medium) - `client/packages/app/lib/src/features/settings/screens/admin/invites_screen.dart:250`.
An outstanding code that makes every redeemer a moderator is visually identical to a plain one, so the invite list cannot be audited.
Note the project's own notes are stale here and claim role-granting invites have no HTTP surface; they do, and it is unaudited.

**The member roster and both of its counts truncate at one 50-member page** (medium) - `client/packages/app/lib/src/features/members/providers/member_presence.dart:20`.
`listMembers()` is called with no paging, so on a 51+ member deployment the rail reads "50 members" and the member pane "MEMBERS · 50", both stated as real counts, and everyone past the first page is unreachable - which is also the only route to a DM.
Invisible on the owner's two-member instance, which is why it will ship.

**Scrolling up stops at whatever the local store holds, and the UI asserts that is the beginning** (medium) - `client/packages/app/lib/src/features/messages/widgets/message_transcript.dart:126`.
`listMessages`'s `before` cursor has zero call sites and there is no scroll trigger.
The recorded gap is pagination; the part worth acting on independently is that `ChannelStartHeader` and a day divider render past the oldest loaded row, so a truncated history states "This is the start of the #general channel."

## 2. Labels that contradict the state, or assert something never checked

**A spent invite is labelled "Expired"** (high) - `client/packages/app/lib/src/features/settings/screens/admin/invites_screen.dart:292`.
The badge falls back to the server's single `usable` bool, which collapses revoked, spent and expired, so a used-up code renders "EXPIRED" directly above "10/10 uses · Never expires".
An admin debugging why a friend cannot join is told a different problem with a different fix, and every field needed to say which is already on the model.

**"Already taken." and "Will be added as :name:" render together** (medium) - `client/packages/app/lib/src/screens/admin/emoji_upload_card.dart:150`.
The two lines always co-occur for a taken name, one in danger red and one promising success, about 8dp apart above a disabled button.

**The onboarding stepper counts to three over a flow with two panes** (medium) - `client/packages/app/lib/src/features/auth/widgets/onboarding_shell.dart:30`.
`OnboardingStep.server` is never passed by any production widget; the fingerprint step builds its own bare `Scaffold`, and the invite path never runs identity confirmation at all.
The stepper exists specifically to say how many steps are left, which is the one thing it does not do.

**The server identity tick is fed reachability, not the pinned fingerprint** (medium) - `client/packages/app/lib/src/features/auth/widgets/onboarding_shell.dart:351`.
Sign-in passes `confirmed: version.identity != null`, so a server whose key changed still ticks; the widget's own doc comment claims the opposite.
The glyph also has no `semanticLabel`, so confirmed and unconfirmed are indistinguishable to a screen reader on the one signal that separates "the server you pinned" from "some server that answered".

**"Overwrite cleared for X" is reported for a no-op** (low) - `client/packages/app/lib/src/screens/admin/channel_overwrites_screen.dart:155`.
Clear is always offered and the server is idempotent, so on the one screen that cannot show current state the user is told a change happened when nothing likely existed - after confirming a destructive dialog to get there.

## 3. Dead controls, and capabilities with no route to them

**Account recovery has no UI at either end** (high) - `client/packages/app/lib/src/features/auth/screens/sign_in_screen.dart:377`.
`resetPassword` and `issueResetCode` both exist client-side, both routes exist server-side, and neither has a single call site.
This is the fourth instance of the same dead-feature shape (`markRead`, `Routes.settings`, `report`/`blockUser`), and `route_reachability_test.dart` cannot see it because the gap is an uncalled API method rather than an unnavigated route.
It compounds with the missing password reveal and the never-committed autofill on the same screen.

**"Assign" is offered on the @everyone row** (medium) - `client/packages/app/lib/src/features/settings/screens/admin/roles_screen.dart:138`.
Profiles never carry the everyone role, so every member reads as switched off and a grant springs back on refetch; `member_roles_sheet.dart` filters it out with a comment saying exactly why, and has a test named for it.

**The "Administrator" overwrite row is inert** (medium) - `client/packages/app/lib/src/permissions.dart:30`.
The evaluator returns everything before overwrites are applied, so Deny cannot reach anyone who holds the bit, and no channel-scoped consumer reads the bit an Allow sets.
The first of sixteen rows on the hardest screen in the product is a control that cannot do what its label implies.

**Every participant becomes inert once somebody shares a screen** (medium) - `client/packages/app/lib/src/features/voice/screens/voice_screen.dart:368`.
`_ParticipantRow` has no tap handler and publishes no semantic action, so the tile's per-participant volume route disappears in exactly the situation where turning one loud person down is what you need.

**The collapsed call strip is not a way back into the call, and never names the channel** (medium) - `client/packages/app/lib/src/features/voice/widgets/voice_strip_indicator.dart:37`.
The only affordance on it hangs up, and its label is a bare participant count while `voice.channelId` sits in the same state object.

**Revoke is offered on an invite nobody can redeem** (low) - `client/packages/app/lib/src/features/settings/screens/admin/invites_screen.dart:309`, gated on `!revoked` rather than `usable`.

**The Notifications pane is a read-only dead end** (low) - `client/packages/app/lib/src/features/settings/widgets/personal_status_sections.dart:85`.
One of seven top-level entries opens onto a single non-tappable line that looks tappable, and in the blocked state it names the problem in the danger colour and offers nothing.

**Add-reaction is revealed by mouse hover only** (low) - `client/packages/app/lib/src/widgets/hover_reveal.dart:35`.
A sixth verb with no keyboard route, alongside the five already recorded; existing reaction chips are properly focusable, so it is specifically the add control.

## 4. Live state the screen never reports

**On a phone the channel screen never says the connection dropped** (medium) - `client/packages/app/lib/src/features/channels/widgets/channel_rail.dart:160`.
`RailConnectionBar` has one call site, in the rail, which is not on screen at compact width; and at every width the transcript only reports offline when the message list is empty.
Sends do fail visibly, so the loss is inbound: the user cannot tell whether nobody is talking or nothing is arriving.

**Nothing signals a message arriving while scrolled up, and the read marker advances anyway** (medium) - `client/packages/app/lib/src/features/channels/screens/channel_screen.dart:224`.
`_scrollToLatest` is only ever called from the send path, and `_markReadUpToLatest` runs unconditionally with no reference to scroll position, so the NEW divider has nothing left to anchor against.

**The report queue never refreshes and has no affordance to ask it to** (low) - `client/packages/app/lib/src/providers/admin_providers.dart:30`.
Fetched once on mount, no report event exists in the wire protocol, no refresh action and no pull-to-refresh - which is also what makes the two state bugs below inescapable without closing the panel.

**Nothing at the entry point says reports are waiting** (low) - `client/packages/app/lib/src/features/settings/screens/space_settings_section.dart:57`.
Manual reporting is the whole safety model, and the only way to learn something was filed is to speculatively open the queue.

**No expiry urgency anywhere in the invite list** (low) - `client/packages/app/lib/src/features/settings/screens/admin/invites_screen.dart:253`.
An invite expiring in ten minutes reads exactly like one expiring in thirty days, in one 12px secondary caption, while `warnText`'s own doc names "an expiring invite" as its purpose.

## 5. Failures are still events, not states

The recorded error-states pass converted 27 SnackBar-only failures; 26 `showSnackBar` call sites remain, 15 of them interpolating `e.message`, and the migration missed the primary screen and every admin screen.
Confirmed independently by six specialists.

**The channel screen and composer carry seven vanishing failures** (medium) - `client/packages/app/lib/src/features/channels/screens/channel_message_actions.dart:45`, plus `composer.dart:238` and `:265`.
The attachment upload is the sharpest: the file did not attach and four seconds later the only explanation is gone with no verb to act on.

**Invite creation flashes a Dart exception, and a non-API throw wedges the button** (medium) - `client/packages/app/lib/src/features/settings/screens/admin/invites_screen.dart:113`.
The catch covers `ApiException` only, so any other throw skips the handler and leaves `_submitting` true at "Creating..." until the modal is closed.
The row 120 lines below in the same file already uses the guarded inline state.

**Overwrite failures are the ones that most need re-reading, and are toast-only** (medium) - `client/packages/app/lib/src/screens/admin/channel_overwrites_screen.dart:125`.
Including the 403 that a genuinely unchanged submit can produce, on a screen where the operator cannot then check what state the server is in.

**Role assignment fails as a toast with the server's fragment in it** (medium) - `client/packages/app/lib/src/screens/admin/role_assign_sheet.dart:45`.
Compounded by no client-side grant check: `myPermissionsProvider` is not read in that file, so every row looks actionable and grants of a role carrying bits the caller lacks round-trip and spring back.

**Devices and Blocked render a load failure as one dead sentence with no retry** (medium) - `client/packages/app/lib/src/features/settings/widgets/personal_account_sections.dart:47`, while the same file uses the real inline error state 80 lines later.

**A raw exception object is interpolated into the voice join preview's visible copy** (medium) - `client/packages/app/lib/src/features/voice/providers/voice_controller.dart:177`.
`lastError` is the caught object, centre-aligned under a heading on the screen a self-hoster hits when their SFU is misconfigured.
Note the sibling path in the same file interpolates it deliberately with a comment defending it, so this is an inconsistency to settle rather than an unambiguous mistake.

## 6. Write paths that mishandle their own state

**Resolving a report leaves `_busy` true and disables the next report's buttons** (medium) - `client/packages/app/lib/src/features/settings/screens/admin/reports_screen.dart:77`.
The flag is cleared only in the catch, and the list has no keys, so when the queue shortens the retained state is handed the next report, whose Dismiss and Resolve then render dimmed and take no taps with nothing said about why.

**"Set overwrite" is an unconfirmed blind replace; the strictly safer "Clear" gets the dialog** (medium) - `client/packages/app/lib/src/screens/admin/channel_overwrites_screen.dart:95`.
The form always opens at all-inherit, so submitting after touching one row replaces every other allow and deny the overwrite carried - and submitting with nothing touched is byte-identical to Clear, so the same destructive effect is reachable both behind and in front of a confirmation.

**A submit that changes nothing can be refused as a privilege escalation** (medium) - `crates/slimm-server/src/http/overwrites.rs:125`.
Because the form always sends deny=0, an existing deny of a bit the caller does not hold in that channel makes an untouched form a 403, explained only by a vanishing toast.

**Non-numeric text in "Uses allowed" silently produces an unlimited invite** (medium) - `client/packages/app/lib/src/features/settings/screens/admin/invites_screen.dart:91`.
`int.tryParse` returns null, the client omits the key, and the server reads that as unlimited; the field has no formatter and never uses the input component's own error slot.
The failure is silent and lands on the most permissive setting, on the screen that controls who gets into the Space.
Zero and negative values are correctly refused server-side.

**Revoking another device and unblocking a user have no error handling at all** (medium) - `client/packages/app/lib/src/features/settings/widgets/personal_account_sections.dart:74` and `:134`.
No try/catch on either, so a failure escapes into the unhandled-async path and the row stays exactly as it was - indistinguishable from "it worked but the list did not refresh", on a security action.

**A long role name is clipped mid-glyph under the action icons** (medium) - `client/packages/app/lib/src/features/settings/screens/admin/roles_screen.dart:108`.
A bare `Text` as a non-flex `Row` child never elides, and the card clips, so the name is cut hard with no ellipsis; the server accepts 64 characters and about 26 fit on a phone.
The design system documents this exact trap for its own row.

**The emoji list is non-lazy** (medium) - `client/packages/app/lib/src/features/settings/screens/admin/emoji_screen.dart:48`.
A `Column` inside a single-child `ListView`, so at the server's own 500 cap opening the screen builds 500 rows and issues 500 image fetches in one frame.

**An operator can lock themselves out of the overwrites screen in one channel** (low) - `crates/slimm-server/src/http/overwrites.rs:73`.
Both verbs are gated on channel-scoped MANAGE_ROLES and the administrator bypass is base-scoped, so a deny against oneself as a member, or against @everyone, is unrecoverable without an administrator - offered as one of sixteen identical-looking rows with no warning.

**Losing the two-moderator race reads as a failure** (low) - `client/packages/app/lib/src/features/settings/screens/admin/reports_screen.dart:83`.
The one concurrency case the server deliberately designed for surfaces as a generic error, and the stale card stays with live buttons that will 404 forever.

## 7. The theme does not carry the palette

Two `buildTheme` gaps account for a large share of the visual drift found on every screen, and both were found from at least two directions.

**`colorScheme.primary` is left to `fromSeed`** (high) - `client/packages/design_system/lib/src/app_theme.dart:31`.
Every raw `FilledButton`, `TextButton` and `OutlinedButton` in the app paints a Material-derived accent instead of `accentFill`: sampled from the renders, "Upload photo" is `#8AD0EE` in dark against a `#58B4D8` token, and `#196584` in light against `#1B6F91`.
The same failure was diagnosed for `error` one audit round ago and fixed by pinning the token; `primary` was left out, so the app's front-door button and its wordmark are two different accents.
Found by the sign-in and settings specialists independently.

**There is no `ListTileTheme` and no input label/hint/helper styles** (medium) - `client/packages/design_system/lib/src/app_theme.dart:110`.
Every raw `ListTile` across settings and space settings takes M3 `onSurface`/`onSurfaceVariant` rather than the text tokens - measured as two different blacks in the same panel - and input labels resolve to unpinned seeded tones, including the focused label, which is the same root as the finding above.
This also produces the visible 8px disagreement between `AppListRow` labels and `ListTile` titles inside one pane.

**The modal panel's declared 1px border paints nothing, in any theme, on any of the nine modal routes** (medium) - `client/packages/app/lib/src/routing/modal_page.dart:105`.
`DecoratedBox` does not inset its child, so the opaque `Scaffold` paints over the stroke; probed per-pixel in both themes by two specialists, with no border colour present anywhere at the panel edge.
It is dead code that reads as live - the file's own comment reasons about that hairline - and the cold-open branch has no other separation than a 1.07:1 tone step.

**Contrast questions still open, for the owner rather than for a sweep**:
`borderSubtle` is reused as the enabled boundary of every text field and every secondary button (`app_tokens.dart:169`), at 1.22-1.38:1, where the recorded "is a hairline a UI component" question does not apply because these are controls, not separators.
The selected inline segmented chip falls under 3:1 by every cue it has in both themes (`segmented_control.dart:125`), and sixteen of them stack on the overwrites screen.
An accent callout's ink sits at 4.45:1 on `accentSoft` in light theme (`callout.dart:76`), just under the body floor.
`borderStrong` clears 3:1 in dark but not in light, so all three need a new light-theme step - and the decision record already considered and rejected the value that would land there.
This is one token decision, not three screen fixes.

## 8. Components bypassed at the call site, and touch density

**Onboarding's three entry cards are a raw `InkWell`** (medium) - `client/packages/app/lib/src/features/auth/screens/onboarding_screen.dart:134`.
The app's first three actions get Material's overlay washes instead of the 2px accent focus ring every other row draws, no haptic, and no trailing glyph, so three identically-weighted bordered rectangles read as callouts.
They also announce their title and description twice - the wrapper has no `container: true` and neither `Text` is excluded, the exact defect the design system already diagnosed and fixed in the component this should use.

**The voice screens hold a third of the app's raw `fontSize` values** (low) - `client/packages/app/lib/src/features/voice/screens/voice_screen.dart:119`.
Nine raw sizes across four files, three of them the off-scale 13, a heading that restates `AppText.heading` while dropping its leading, and a hand-rolled 50pt CTA where the largest button token is 40 - so the most-pressed control in a call has no focus ring and no haptic.

**The voice channel header is a second, divergent copy of the channel header** (medium) - `client/packages/app/lib/src/screens/home_shell.dart:203`.
Measured in the renders: the title jogs 5.5px sideways (s16 against `paneGutter`), drops a type step while gaining weight, and the kind glyph inherits the seeded `onSurface` - pure white in dark, the brightest ink in the header, in a colour `AppTokens` does not contain.

**A disabled `AppToggle` is pixel-identical to an enabled one** (medium) - `client/packages/design_system/lib/src/components/forms/toggle.dart:60`.
Every painted value reads `value` only; `interactive` reaches only the tap target.
So in the role editor a permission the caller cannot grant is a switch that looks live and does nothing, with the reason carried by label colour alone, and no caption - while the sibling sheet does supply one.

**The microphone pre-toggle looks like a read-only field and reports itself as neither button nor toggle** (medium) - `client/packages/app/lib/src/features/voice/screens/voice_screen.dart:249`.
`InkWell` publishes no `button: true` and no `toggled:`, and in the render it is a 42dp bordered box reading "Microphone … on" with no switch, chevron or accent, directly above a filled CTA that looks like the only interactive thing on screen.
Pre-muting before the mic opens is the screen's stated purpose.

**Density**: `AppInput` has no `touch` flag at all (`client/packages/design_system/lib/src/components/forms/input.dart:105`), so every text field in the app is 38dp on a phone against this project's own 44 floor - found twice, and the 44pt height already exists as the `lg` step.
Composer autocomplete rows are a hardcoded 34dp with no gap between neighbours (`composer_autocomplete.dart:123`), in a composer that resolved the touch signal into a local variable two lines earlier - the surface a phone user taps most in the emoji feature.
Sign-in's three raw Material buttons draw at 40dp (`sign_in_screen.dart:351`); the tap targets pass, the drawn control is 4px under the system's own value.
And the codebase holds two contradictory written answers to whether width is a proxy for input modality (`touch_targets.dart:38` against `composer_extras.dart:22`), which at 844x390 drops every control on the channel screen to pointer size on a rotated phone.

**`AppInput` reserves its focus ring as layout** (medium) - `client/packages/design_system/lib/src/components/forms/input.dart:182`.
A 4dp inset on all four sides means a field's drawn edge sits inside every sibling control in the same card; six other components in this repo solve the same problem with a foreground decoration that reserves nothing.

## 9. Keyboard and screen reader

**The autocomplete popup is silent** (medium) - `client/packages/app/lib/src/features/composer/widgets/composer_autocomplete.dart:113`.
No live region anywhere in the file and focus never moves into it, so up to eight suggestions open above the caret with no announcement that offers exist and none when the selection changes - meaning Enter substitutes text the user never heard about.

**Nav group labels are their own accessible name, uppercased** (medium) - `client/packages/app/lib/src/features/settings/widgets/settings_panes.dart:239`.
The rail and the member pane both do the opposite, with a comment explaining that some screen readers spell such a word out; the new settings nav is the one site that regressed, on the only structure a screen-reader user has for navigating it.

**Nothing announces or focuses a field-scoped failure** (low) - `client/packages/app/lib/src/features/auth/screens/sign_in_screen.dart:342`.
The form-scoped error is a live region and announces at once; the three field errors are reachable but not announced when they appear, and focus stays on the submit button - so the most common failure, a wrong password, reads as the button having done nothing.

**A disabled segmented option never says why** (low) - `client/packages/design_system/lib/src/components/forms/segmented_control.dart:31`.
The `hint` slot is cards-only, so a screen reader hears "Allow, button, disabled" with no reason, and a sighted user sees a slightly paler word among sixteen rows.
The row already knows the reason.

**Every invite row's destructive button reports the same name** (low) - `client/packages/app/lib/src/features/settings/screens/admin/invites_screen.dart:312`.
"Revoke invite" with no code in it, and the card carries no group label, so control-by-control navigation gives N identical buttons; the confirmation dialog does quote the code, which is the mitigation.

**A message timestamp carries no full date on hover or in semantics** (low) - `client/packages/app/lib/src/features/messages/widgets/message_row_identity.dart:105`.
A bare `HH:mm` is unresolvable on its own, and the day divider that would resolve it may be many screens above.
The 24-hour fixed-width format itself is a documented layout constraint and should not be changed.

**The mode flip on sign-in rewrites the page, including adding a required field, and announces nothing** (low) - `client/packages/app/lib/src/features/auth/screens/sign_in_screen.dart:362`, while incidental server notices each announce themselves.

## 10. The modal frame, and the emptiness inside it

Found from four directions; it is one frame-level problem showing up on nine screens.

**The desktop panel is a fixed 860x720 whatever it holds** (medium) - `client/packages/app/lib/src/routing/modal_page.dart:90`.
The child `Scaffold` expands into loose constraints, so the panel never sizes to content, contradicting the file's own doc comment ("the panel is only as big as it needs to be").
Measured: the settings Account pane is ~70% empty, space settings 25%, channel overwrites ~62% in the state every deployment opens first, and the invites and reports panels are a form or a sentence in a void.
Note three of the seven personal-settings panes hold one row each, so the emptiness is partly over-division rather than only a sizing bug.

**Between 600 and 892px the panel has no horizontal gutter** (low) - same file, `:90`.
The height reserves 14% for scrim and the width reserves nothing, so a half-screen desktop window gets a modal flush against both edges but inset top and bottom.
No viewport in the matrix covers that band.

**Compact drill-down in settings is local state, not a route** (medium) - `client/packages/app/lib/src/features/settings/widgets/settings_panes.dart:108`.
The visible arrow goes up one level while Android back, the iOS edge swipe and a barrier tap dismiss the whole panel from any depth - two affordances in the same position with different destinations - and the pane change is invisible to a screen reader because the navigation stack never changed.

**The space-settings list is ragged against its own title at both widths, in opposite directions** (medium) - `client/packages/app/lib/src/features/settings/screens/space_settings_screen.dart:24`.
16pt on a phone and 53.5pt on desktop, because this is the one admin screen that passes `EdgeInsets.zero` and never re-applies the inset; the first row is also flush against the app bar.
A milder version of the desktop half exists on every screen using the shared scaffold, where the app bar sits outside the capped content column.

**Personal settings and space settings are two different settings designs in the same panel** (medium) - `client/packages/app/lib/src/features/settings/screens/space_settings_screen.dart:19`.
One is a centred capped column of iconned rows with descriptions; the other is a flush-left 240px nav of bare labels.
Every future settings change is made twice, and the two frames have already diverged on content width.

**Empty states are what ships to a new deployment, and they teach nothing** (low).
"The queue is empty." in a 720pt panel (`reports_screen.dart:37`), "No invites yet." with no pointer at the form above it, "No emoji yet." with no mention of the bulk-import CLI that exists, and a roles empty state whose copy names the control by its shape ("+") when the control announces itself as "New role".
There is no empty-state component in the design system, so this is one shared gap across eight screens rather than eight screens' worth of copy.

## 11. What the snapshot gate never sees

Every specialist reached this, and it is the single best explanation for why the highest-severity defects survived.

**Populated rows have never been rendered** (medium) - `client/packages/app/test/ui_snapshot_support.dart:158`.
The fixture's catch-all answers `[]`, so the invites, roles, reports and emoji screens are all snapshotted in their empty state - and the roles empty state is one the server cannot produce at all, because bootstrap guarantees two roles.
The clipped role name, the mislabelled spent invite and the unclamped report bodies all live in states no render and no overflow assertion has ever produced.

**The screens that change structure by width are snapshotted at two widths** (low) - `client/packages/app/test/ui_snapshot_test.dart:42`.
`_phoneAndDesktop` is justified by a comment saying these screens are "a single column either way", which is false for onboarding and sign-in (900px panel floor, 420px stepper threshold), for settings (800px two-pane floor) and for every modal (600px presentation floor).
`desktop-narrow` at exactly 900 and `phone-landscape` at 844x390 are already defined and rendered for none of them.

**The harness is not what ships** (medium) - `client/packages/app/test/ui_snapshot_test.dart:96`.
It builds its own bare `MaterialApp.router` with no `builder`, so it omits `main.dart:114`'s app-wide `ListTileTheme.merge(dense: ...)` and renders every desktop settings and admin screen at touch density; it also starts the router at the modal route, so `canPop()` is false and the panel renders without its float shadow and scrim.
One finding in this audit pass was generated by exactly that artifact.
Separately, no viewport sets `platform`, so every render is Android and the desktop composer's newline hint and hardware-Enter path are in no picture and outside the overflow gate.

**The phone-width settings layout test no longer exercises any pane content** (medium) - `client/packages/app/test/personal_settings_screen_test.dart:182`.
The redesign made panes lazy, the test opens none, and the comment above the drag still claims it catches the overflow it was written for.
`VoiceSettingsBody`, the densest pane in the app, is now laid out at phone width by nothing at all.

**The in-call voice tree is reached by two tests at two or fewer participants, one viewport each** (low) - `client/packages/app/test/ui_snapshot_test.dart:55`, so the tile grid, the share-stage split and the control bar are ungated at the counts the code says it is sized for.

**"Removed members" is pinned to no permission bit** (low) - `client/packages/app/test/features/settings/settings_space_section_test.dart:22`.
Six of seven rows are asserted in both directions; showing that one to a CREATE_INVITE-only caller passes green, and dropping it for a BAN_MEMBERS holder passes green too.

## 12. Copy, naming and information architecture

**"Delete account" is filed inside the pane labelled "About slim-m", beside the version number** (medium) - `client/packages/app/lib/src/features/settings/screens/personal_settings_screen.dart:95`, one group below a group called YOU, with the pane's own title and its section header disagreeing.

**Nothing in the UI states the overwrite precedence rules** (low) - `client/packages/app/lib/src/screens/admin/channel_overwrites_screen.dart:212`.
Role and Member are tiers, not flavours, and deny wins across roles - a deliberate deviation from the convention operators arrive with - so a role Allow with no effect reads as a broken screen.

**Sixteen tri-state rows with no card, no grouping and no heading, and voice permissions offered on text channels** (medium) - `channel_overwrites_screen.dart:245`.
Surface weight runs opposite to consequence: the two least consequential controls sit in titled cards and the sixteen consequential ones sit loose in a column with nothing saying what the block is.

**"Anyone with the address" is offered as a neutral peer with no caveat** (low) - `client/packages/app/lib/src/features/settings/widgets/join_policy_row.dart:105`.
The picker it uses takes a footnote for exactly this and has a working precedent two files away; nothing anywhere in the client explains what an open Space means.
The same setting is called "Who can join" on the row and "Who can create an account" in the sheet it opens.

**Continue is gated on accepting terms that do not exist anywhere in the product** (low) - `client/packages/app/lib/src/features/auth/screens/onboarding_screen.dart:272`.
The checkbox is a recorded Play compliance requirement and should stay; the gap is that the document it names is not on screen, not linked and not served.

**A settings cog is the icon for "Connect to a Space"** (low) - `client/packages/app/lib/src/features/auth/screens/onboarding_screen.dart:77`, the only one of three entry glyphs that actively misdescribes its row.
Similarly, "Removed members" is drawn with the sign-out glyph (`space_settings_section.dart:91`), which means signing out one screen away, and "Delete account" uses the alert-circle (`personal_account_sections.dart:170`) while a trash glyph exists - so when a delete fails the pane shows two red alert glyphs meaning two different things in one column.

**Copy hands over half of what the recipient needs** (low) - `client/packages/app/lib/src/features/settings/screens/admin/invites_screen.dart:194`.
The clipboard gets a bare 10-character code; the redeeming side needs a server address in a separate field, and the clipboard is the one moment the screen knows both halves.

**Delete confirmation is a filled danger button** (medium) - `client/packages/app/lib/src/features/settings/widgets/personal_account_sections.dart:234`.
The single place in the app that fills a control with the danger colour, in a hand-rolled copy of a shared dialog whose replacement grew a `cancelLabel` parameter specifically for this caller, with a comment saying so.
Conversely, resolving a report goes through the same danger helper (`reports_screen.dart:65`), so the desired outcome is re-presented as destructive one tap after being offered as the accent primary.

**The typing indicator sets a human sentence in the monospace face** (low) - `client/packages/app/lib/src/features/composer/widgets/composer_extras.dart:298`, where every other mono site in the system is a date, time, count or keycap.

## 13. Cleanup, and notes that have gone stale

**Five stale or orphaned doc comments left by the settings redesign** - `client/packages/app/lib/src/features/settings/screens/personal_settings_screen.dart:11` ("five panes" for seven), an orphaned block at the end of `personal_status_sections.dart` arguing for the design the redesign reversed, and two files claiming "Reached with `go()`, so there is no stack to pop" when every call site pushes - which is the exact reasoning the drill-down navigation finding turns on.

**`_PinPill`'s doc comment describes a gap that closed two passes ago** - `client/packages/app/lib/src/features/channels/widgets/channel_header.dart:121`, pointing the reader at a known-gaps note that has since been struck.

**Header action order differs between desktop and phone** - `channel_header.dart:96` against `compact_channel_app_bar.dart:82`: pin/search/members against search/pin/members, for no reason either width motivates.

**Day dividers, the unread divider and the start header ignore `kMessageColumnMax`** - `client/packages/app/lib/src/features/messages/widgets/message_row_parts.dart:234`.
Three separators drawn wider than the column they divide, and the gap grows without bound on a wide monitor - the same bug the message body already had and fixed, in the widgets split out afterwards.

**The transcript flips layout between zero and one message** - `client/packages/app/lib/src/features/messages/widgets/message_transcript.dart:108`.
The empty case takes a scroll view and the non-empty case a reversed list, so sending the first message moves the welcome block from the top of the pane to the bottom.

**Off-grid and doubled spacing**: two stacked spacers where the camera pre-toggle was removed (`voice_screen.dart:147`), two stacked s8 spacers straddling a conditional chip on sign-in (`sign_in_screen.dart:266`) - the shape `ServerNotice` was refactored to avoid - a 6px gap in a file otherwise on the 4dp grid (`onboarding_shell.dart:266`), 10/6 padding on nav group labels putting them 2px proud of every row they head (`settings_panes.dart:238`), a trailing spacer under the last emoji row (`emoji_screen.dart:50`), and three sites shrinking `AppText.code` by hand while keeping the letter-spacing computed for 13.5px (`onboarding_shell.dart:259`).

**Off-scale type**: `fontSize: 13` at roughly a dozen sites and `16`/raw `w600` at several more, including the settings section header that heads every pane (`settings_section_header.dart:73`) while its sibling fourteen lines up uses the named tokens correctly.
This is pre-existing project-wide drift, worth one sweep rather than a dozen tickets.

**Over the review budget**: `invites_screen.dart` (322), `composer.dart` (412), `channel_screen.dart` (374, down from 583), `onboarding_screen.dart` (396) and `onboarding_shell.dart` (357).
Every fix listed above adds to one of these.

**Multi-line rationale carried on `///` attached to statements inside method bodies** - `onboarding_screen.dart:217` and `:328`.
The reasoning is worth keeping (one is the client-side half of the deliberate no-invite-metadata rule), which is why it belongs on the enclosing method rather than being shortened away; the comment-cap gate will not catch either by design.

## The three to do first

**1. Give the report card an identity, and the queue a way to act.**
`reports_screen.dart` is the only screen in this audit that cannot perform its stated purpose: the moderator is asked for an irreversible close on a subject the screen does not name, and for a user report there is no identifying information on screen at all.
Everything it needs is already on the model and already served, and the batch profile fetch exists.
It is also the one finding here that is a safety-model problem rather than a polish problem.

**2. Pin `primary` and add a `ListTileTheme` in `buildTheme`.**
Two additions in one file correct the brand accent on every raw Material button in the app and the row text and icon colour on all fifteen raw `ListTile` sites, which between them account for a large share of the "off-palette" findings on every screen.
`error` was pinned for exactly this reason one audit round ago; this is finishing that change rather than starting a new one.
The same file is where the input label and hint styles belong, and the dead modal border is one line away in `modal_page.dart`.

**3. Point the snapshot fixture at real data, at the widths where layout changes, through the shipped app wrapper.**
The three highest-severity screen defects - the clipped role name, the mislabelled spent invite, the unclamped report body - all live in states no render and no overflow assertion has ever produced, and one finding in this pass was generated purely by the harness diverging from `main.dart`.
Until the gate renders populated rows at the breakpoints that matter, under the density and presentation the product actually ships, every fix above is unprotected and the next equivalent defect will survive the same way.

Runners-up, close behind: the spent-invite label (a one-condition correctness fix on a screen an operator uses to debug why a friend cannot join), and the missing image preview on the emoji upload.
