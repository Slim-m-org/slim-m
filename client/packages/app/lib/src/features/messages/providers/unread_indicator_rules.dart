// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Pure decision logic for what a channel row shows as unread, kept apart
/// from the widgets so every surface that can light a channel reads one rule
/// rather than its own copy - the split `notification_sound_rules.dart`
/// already uses for the chime's own gate.
///
/// See `docs/decisions/0049-per-channel-notification-behaviour.md` for the
/// owner's own wording of the rule each branch below implements, and for why
/// hiding an indicator never changes what is actually read.
library;

import 'package:slimm_api/api.dart' as api;

/// The two flags `AppListRow` reads, after a channel's own override has had
/// its say.
typedef UnreadIndicator = ({bool unread, bool mentioned});

/// What to paint for one channel, given the raw read state behind it.
///
/// Decides only what is drawn. Read state itself - the marker, the transcript
/// divider, what counts as delivered - is untouched, so a quiet channel keeps
/// accumulating unread messages and keeps clearing them on open exactly as a
/// loud one does.
///
/// [channelOverride] is `null` for a channel following the account default,
/// and never [api.NotificationPreference.everything] in practice, since the
/// server refuses to store that as an override. The account-wide preference
/// is deliberately not consulted: it answers which messages are worth waking
/// a device for, and reading it here would leave an account set to mentions
/// with no unread indication anywhere at all.
///
/// [manuallyUnread] is the reader's own hand-mark, the one thing that still
/// shows on a muted channel: it is a note somebody left themselves, not a
/// notification the override was asked to silence.
///
/// A DM under [api.NotificationPreference.mentions] stays loud: writing there
/// is addressing this account directly, the same reading the server's own
/// `narrow_for_notification_preference` takes of it. Only an outright mute
/// quietens one.
UnreadIndicator unreadIndicatorFor({
  required api.NotificationPreference? channelOverride,
  required bool isDm,
  required bool unread,
  required bool mentioned,
  required bool manuallyUnread,
}) => switch (channelOverride) {
  // Nothing at all, a mention included.
  api.NotificationPreference.nothing => (
    unread: manuallyUnread,
    mentioned: false,
  ),
  // Nothing until a mention.
  api.NotificationPreference.mentions when !isDm => (
    unread: manuallyUnread,
    mentioned: mentioned,
  ),
  _ => (unread: manuallyUnread || unread, mentioned: mentioned),
};
