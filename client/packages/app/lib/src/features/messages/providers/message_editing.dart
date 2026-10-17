// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Which message, if any, is swapped into its inline edit field.
///
/// This used to be a plain field on `_ChannelScreenState`, written through
/// `setState`. That made starting, cancelling or submitting an edit rebuild
/// the *whole* transcript: every visible `MessageRow` got a fresh instance
/// and re-parsed its markdown body, not only the one row whose `editing`
/// flag actually changed. Routing it through a provider each row reads with
/// `.select` (the same shape `messageExtrasProvider` already uses; see its
/// own doc comment) means a row only rebuilds when its own answer changes.
///
/// `autoDispose.family` keyed by channel id, matching `channelSearchProvider`:
/// `ChannelScreen`'s own `State` can outlive a channel switch, so a plain
/// (non-family) provider would let an edit started in one channel keep
/// showing after switching to another.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

final editingMessageIdProvider = StateProvider.autoDispose
    .family<String?, String>((ref, channelId) => null);
