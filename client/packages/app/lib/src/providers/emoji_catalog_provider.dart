// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The deployment's custom emoji as the render side needs them: a name-to-id
/// index for resolving `:shortcode:`, and one emoji's image bytes.
///
/// Named `emoji_catalog_provider` rather than `emoji_catalog` because
/// `widgets/emoji_catalog.dart` already holds the unicode picker's catalog,
/// which is a different thing entirely: that one ships with the app, this one
/// is whatever the deployment uploaded.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart';

import 'admin_providers.dart';
import 'emoji_image_cache.dart';
import 'providers.dart';

/// Emoji name (already lower-case, the server normalises it) to emoji id, for
/// resolving a `:shortcode:` while rendering a message.
///
/// Reads [customEmojiProvider] rather than fetching `GET /emoji` again, so the
/// administration screen and every message row share one list and one
/// invalidation: uploading or deleting an emoji there invalidates that
/// provider, and the next frame renders through this index. Two providers over
/// the same endpoint would leave a freshly uploaded emoji unrenderable until
/// relaunch.
///
/// This provider is not `autoDispose`, which also keeps the (`autoDispose`)
/// list alive for the session: message rows come and go as a list scrolls, and
/// letting the last one out of the tree drop the set would refetch it as soon
/// as the next one arrived.
///
/// Empty while the set is loading and empty if the fetch failed, which is the
/// same answer in both cases on purpose: an unresolved shortcode renders as
/// the literal text the member typed, so a slow or broken emoji list degrades
/// to plain text rather than to a gap.
final customEmojiIndexProvider = Provider<Map<String, String>>((ref) {
  final emoji = ref.watch(customEmojiProvider).valueOrNull ?? const [];
  return {for (final e in emoji) e.name: e.id};
});

/// How many [customEmojiImageProvider] fetches may be in flight at once,
/// across every family member.
///
/// `Class::Asset` (`ratelimit/class.rs`) buckets attachment, avatar and emoji
/// reads together with a burst of 150 and a refill of 25/second; its own doc
/// comment sizes that burst for "a full member page plus a transcript's own
/// avatars", which `member_pane.dart`'s plain (non-lazy) `ListView` can
/// realise in full the moment the pane opens - every member's avatar, at
/// once, is the honest worst case that burst already has to absorb. The
/// picker grid is lazy (`GridView.builder` in `emoji_picker_grid.dart`), but
/// a phone-width sheet still mounts on the order of fifty cells at first
/// paint, and scrolling mounts more - so an unbounded picker competes with
/// that same avatar burst for the same 150 tokens rather than the handful of
/// rows the settings-screen fix (#942) left as the largest sanctioned burst
/// from one screen (that fix bounds it below 50 rows; see
/// `emoji_admin_screen_scale_test.dart`).
///
/// Six keeps the picker's own share small next to that: even if every
/// visible cell needs a fetch, six in flight plus the class's 25/second
/// refill clears them in a couple of seconds without ever holding more than
/// 4% of the burst at once, leaving the other 96% for whatever avatars are
/// resolving alongside it. Past this cap a cell's fetch simply waits its
/// turn instead of firing and risking a 429 - the queue this bounds is
/// exactly what let the unbounded version blow the budget in the first
/// place. The retry loop below stays as the safety net under it, not the
/// primary defence.
@visibleForTesting
const emojiImageFetchConcurrencyCap = 6;

/// A small counting semaphore: [acquire] resolves once a slot is free,
/// [release] frees one and hands it straight to the longest-waiting caller
/// (FIFO), so a cell that has been waiting is served before one that just
/// mounted.
class _Semaphore {
  _Semaphore(this._available);

  int _available;
  final Queue<Completer<void>> _waiting = Queue();

  Future<void> acquire() {
    if (_available > 0) {
      _available--;
      return Future.value();
    }
    final completer = Completer<void>();
    _waiting.add(completer);
    return completer.future;
  }

  void release() {
    final next = _waiting.isEmpty ? null : _waiting.removeFirst();
    if (next != null) {
      next.complete();
    } else {
      _available++;
    }
  }
}

final _emojiImageFetchLimiter = _Semaphore(emojiImageFetchConcurrencyCap);

/// The disk cache behind [customEmojiImageProvider], as its own provider so
/// a test can hand it an in-memory fake rather than touch a real filesystem.
///
/// Defaults to [NoopEmojiImageCache], not [createEmojiImageCache]: the real
/// backend's own doc explains why a container has to opt into it explicitly
/// (`main.dart` does, for the running app) rather than have every consumer,
/// including a widget test that never asked for it, reach `path_provider` by
/// default.
final emojiImageCacheProvider = Provider<EmojiImageCache>(
  (ref) => NoopEmojiImageCache(),
);

/// How long a fetch that exhausted every retry waits before quietly trying
/// again on its own, for whichever cell is still watching it.
///
/// Without this, the provider below (deliberately not `autoDispose`) would
/// cache a spent-out [RateLimitedException] as this emoji's answer for the
/// rest of the session - the same forever-broken image #945 stopped for the
/// common case, just still reachable on the rare path where every retry
/// below also lands on a 429. Comfortably past the retry loop's own longest
/// wait (2s, before the fourth and final attempt), so this does not race the
/// same window the retries already lost; the concurrency cap above is what
/// makes reaching this path rare in the first place.
///
/// A `var`, not a `const`, so a test can shrink it rather than spend ten real
/// seconds proving the heal actually happens.
@visibleForTesting
var emojiImageTombstoneCooldown = const Duration(seconds: 10);

/// One emoji's image bytes, by emoji id.
///
/// Not `autoDispose`, for the reason above and because the same emoji recurs
/// down a transcript: evicting it the moment it scrolls out would refetch it
/// on the way back. Bounded rather than unbounded, unlike an attachment cache:
/// the set is capped at 500 (`MAX_CUSTOM_EMOJI`, `store/emoji.rs:15`) and each
/// image at 1 MiB (`MAX_IMAGE_BYTES`, `emoji.rs:34`). Once fetched, an emoji's
/// bytes stay cached on this provider for the rest of the session, so
/// scrolling the picker back over cells it already realised decodes nothing
/// new.
///
/// [emojiImageCacheProvider] is checked first, so a repeat visit - including
/// one on a later app launch, where this provider itself starts cold - can
/// skip the network (and the rate limit it shares with avatars) entirely.
/// A hit there is the primary defence against the picker's own burst; the
/// concurrency cap below only bounds what a genuine cache miss can do, which
/// is largest exactly once, the first time a deployment's catalog is seen.
///
/// A network fetch waits on [_emojiImageFetchLimiter] before it ever reaches
/// the network, so no more than [emojiImageFetchConcurrencyCap] of these are
/// ever outstanding at once no matter how many cells mount together - the
/// picker grid does that on first paint, and the emoji settings screen used
/// to before #942 made its own list lazy. The semaphore is acquired again for
/// each retry attempt below rather than held across the backoff delay, so a
/// rate-limited fetch backing off does not itself occupy a slot another
/// cell's first attempt could use.
///
/// The retry-with-backoff loop is the fallback, not the primary defence: with
/// the concurrency capped, a burst should rarely reach the limiter at all,
/// but a request already in flight when another caller's burst lands can
/// still draw a [RateLimitedException]. Retried the same way
/// `CanvasSync._fetchPage` retries a rate-limited page fetch, honouring the
/// response's own `Retry-After` when it carries one rather than only this
/// loop's fixed schedule. If every retry still fails, [_healAfterCooldown]
/// schedules one more attempt after [emojiImageTombstoneCooldown] rather than
/// leaving this emoji's answer permanently broken for a cell still on screen.
/// The same holds for a dropped connection or a 5xx, see [_isTransient].
final customEmojiImageProvider = FutureProvider.family<Uint8List, String>((
  ref,
  emojiId,
) async {
  final cache = ref.watch(emojiImageCacheProvider);
  final cached = await cache.read(emojiId);
  if (cached != null) return cached;

  final api = ref.watch(apiProvider);
  var delay = const Duration(milliseconds: 250);
  for (var attempt = 0; ; attempt++) {
    await _emojiImageFetchLimiter.acquire();
    Uint8List? bytes;
    Duration? retryAfter;
    try {
      bytes = (await api.fetchCustomEmojiImage(emojiId)).bytes;
    } on ApiException catch (e) {
      // Only a rate limit is retried in place; any other failure goes straight to the cooldown.
      if (e is! RateLimitedException || attempt >= 3) {
        if (_isTransient(e)) _healAfterCooldown(ref);
        rethrow;
      }
      retryAfter = e.retryAfter;
    } finally {
      _emojiImageFetchLimiter.release();
    }
    if (bytes != null) {
      await cache.write(emojiId, bytes);
      return bytes;
    }
    await Future<void>.delayed(retryAfter ?? delay);
    delay *= 2;
  }
});

/// Whether [e] is the kind of failure that passes by itself: a rate limit, a
/// dropped connection or a server that is briefly down. A refusal, a missing
/// emoji or a bad request would only fail the same way again, so it is left
/// as the answer rather than retried every cooldown for as long as a cell is
/// on screen.
bool _isTransient(ApiException e) =>
    e is RateLimitedException ||
    e is TransportException ||
    e is UnavailableException;

/// Schedules a self-invalidation of the currently-building
/// [customEmojiImageProvider] entry, so a rate limit that outlasted every
/// retry does not stay this emoji's answer forever. See
/// [emojiImageTombstoneCooldown]'s own doc for why a wait, not an immediate
/// retry.
///
/// The provider is never manually disposed (it is deliberately not
/// `autoDispose`), so the only reason [Ref.invalidateSelf] would fail here is
/// the whole container going down with it, and there is nothing left for a
/// self-heal to do at that point either way.
void _healAfterCooldown(Ref ref) {
  Future<void>.delayed(emojiImageTombstoneCooldown, () {
    try {
      ref.invalidateSelf();
    } catch (_) {
      // See the doc above: nothing left worth healing.
    }
  });
}
