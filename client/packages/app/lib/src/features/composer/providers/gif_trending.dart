// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The GIF picker's default content, so it opens on trending results rather
/// than a blank grid every time - see `widgets/gif_picker.dart`'s own doc
/// comment for that "something to look at before you type" behavior.
///
/// This used to live as widget state on `_GifPickerBodyState`, which dies
/// with the picker: every open re-fetched the same trending list from the
/// configured provider, showing a loading flicker for content that had not
/// changed since the picker was last closed.
///
/// Deliberately not `autoDispose`, for exactly the reason above - the same
/// tradeoff `customEmojiIndexProvider` (`emoji_catalog_provider.dart`) makes
/// for its own "small, low-stakes, session-length" cache: an `autoDispose`
/// provider is dropped the instant the picker's `ConsumerState` unmounts
/// (which happens as soon as the sheet finishes closing), so it would
/// recreate this exact bug rather than fix it.
///
/// Cached for the whole session rather than on a timer, also matching that
/// precedent: a trending list does go stale over hours, but nothing here is
/// correctness-sensitive the way a message or a permission is, so a session
/// that reopens the picker many times in a row is better served by zero
/// extra round trips than by a periodically-refreshed one. A `keepAlive()`
/// plus a `Timer` was considered and rejected for the same reason
/// `cache_for.dart`'s own doc comment gives: the timer would outlive every
/// test's `tearDown` and fail Flutter's pending-timer check. Restarting the
/// app clears it, the same "good enough" boundary the emoji catalog accepts.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;

import '../../../providers/providers.dart';

/// Keyed by the channel the GIF is headed for, which decides who may browse.
final trendingGifsProvider =
    FutureProvider.family<List<api.GifResult>, String?>(
      (ref, channelId) =>
          ref.watch(apiProvider).fetchTrendingGifs(channelId: channelId),
    );
