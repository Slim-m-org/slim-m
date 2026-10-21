# Wording table

One word for each kind of action and name, so two panes never say the same thing two ways.
The strings live in `client/packages/app/lib/src/action_labels.dart`; a gate in `test/wording_gate_test.dart` fails if a retired spelling returns.
The copy limits under Settings copy are enforced by `test/settings_copy_gate_test.dart`.

## Verbs

- Create for a server-side object: Create channel, Create category, Create role, Create invite, Create emoji, Create bot, Create webhook, Create a reset code.
- Add reaction for a reaction, everywhere (hover toolbar, context menu, picker). A reaction is attached to a message, not created.
- Remove for taking someone out of the Space: "Remove from Space...", the "Removed members" pane and the "Remove members" permission. Never kick.
- Ban stays its own word, because it is a different action.

## Names

- Space is the one word for a deployment inside the app. The sign-in screen's Server field is the address of the thing being connected to and is a separate owner decision.
- Settings > Media and cache is this device's media and cache options.
- Settings > Desktop is how the app behaves on this device: start on login, startup splash, message page size.
- Space settings > Operations > Retention and limits is the Space's message retention and canvas cap.
- The group heading in Space settings is Operations, not Server.

## Patterns

- One empty state for a settings or admin list: `SettingsEmpty`, a sentence in a card at the top left. Inside an existing card use `SettingsEmptyLine`.
- One create button per pane, in the title bar when the pane has one. A list does not repeat it.
- A section title never repeats its pane title.
- Sibling destructive buttons sit at the card's own inner padding, with no extra wrapper.

## Settings copy

A settings row is a few words, and says what the setting does in plain terms.
Concise and clear, always.

- A row label is at most 5 words.
- A description, when the label does not already say it, is at most 12 words and one sentence.
  Ideally it fits on one line on a phone.
- Say what the setting does, never how it is implemented: no relay, encryption, token or protocol detail in the row.
- Never state a default ("Off by default"): it goes stale the day the default changes.
- Do not invent a "Learn more" unless the page it opens exists.
- Detail a member does need goes in the docs, and the row links nothing.

The numbers come from the audit of every row at the time the gate landed.
The longest label that read well was 5 words ("Require Face ID or fingerprint", "Message, mention and error sounds").
The longest description that read well was 12 ("Install a new version with your package manager while slim-m starts").
A tighter cap would force rewrites that lose meaning, and a looser one would admit the three-line paragraphs this rule exists to stop.

The gate reads `description:` and `sheetFootnote:` arguments, named description constants, and the `label:` of `SettingsToggleRow` and `SettingsSelectRow`.
Exceptions go in `client/packages/app/test/settings_copy_allow.txt`, one `path|start of the text` per line, and each needs a reason in the pull request that adds it.

### Detail that left the rows

- Spotify: the token stays on this device and turning the switch off deletes it.
  To revoke slim-m on Spotify itself, use the apps page of the Spotify account.
- Analytics: turning it off hides the numbers but keeps what was already recorded.
- Dock host access: the data store holds up to 256 entries and 64 KB, no other module can read it, and uninstalling deletes it.
  Posting is limited to where the person running the module could post, and is rate limited.
- Push-to-talk: the key is ignored while the message box has focus, and never opens the microphone there.
- Channel join muted: to stop people speaking, deny Speak instead.
- Message retention: nothing is deleted until a window is set.
- Slow mode: a member who can manage the channel is never slowed.
- Gif autoplay: on hover or tap holds a gif on its first frame, which saves battery, and gifs pause while the window is in the background.
- Attachment preview quality: a lower setting decodes smaller, so more fit in the image cache, and opening one always shows full resolution.
- Image cache: a lower limit saves memory, and images redraw a moment slower when scrolled back to, without being downloaded again.
- Startup splash: the value is a minimum, so a slower start is never held back further.
- Lock screen preview and app lock: the server never sees a face or fingerprint, and app lock only gates an already signed-in app.
- Block list: blocked people are not told, stay in the member list, and unblocking restores everything.
- Reports: nothing in the list says who looked at a report or what they decided.
