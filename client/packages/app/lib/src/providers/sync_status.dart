// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// How the sync connection is doing, and what the UI shows for it.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// How the connection is doing, for the UI to show honestly rather than
/// pretending everything is fine while messages silently stop arriving.
enum SyncStatus { offline, connecting, live }

/// Whether this session's first catch-up round has completed, independent of
/// whether the live socket then attaches.
///
/// Read by the transcript ([MessageTranscript.historyKnown]) so an optimistic
/// send made before the very first catch-up lands does not briefly anchor a
/// day divider it does not really own - see `isNewDay`'s own doc comment.
/// Deliberately not folded into [SyncStatus]: that flips back to
/// `connecting`/`offline` on every later reconnect, while this only ever
/// needs to become true once and stay true for the session, since a
/// reconnect's catch-up can only confirm history already known, never
/// un-confirm it.
final initialSyncCompleteProvider = StateProvider<bool>((ref) => false);

/// Whether this session has had a connect attempt actually fail since it was
/// last [SyncStatus.live]: latched true the moment [start]'s catch block
/// gives up on one, cleared the moment the socket attaches.
///
/// Read by `shouldShowBootSplash` so a phone's retry loop only ever covers the app
/// with the boot splash for the genuine first attempt, and by
/// [SpaceConnectionDot]/[RailConnectionBar] (through [displaySyncStatus]) so
/// their reading of the connection does not itself flip between "Connecting"
/// and "Offline" on every retry - once a session has genuinely failed to
/// connect, the reader has already seen that, and re-announcing it every
/// backoff cycle tells them nothing new.
final hasFailedSinceLiveProvider = StateProvider<bool>((ref) => false);

/// The [SyncStatus] to actually show, collapsing a retry's
/// [SyncStatus.connecting] attempt into [SyncStatus.offline] once
/// [hasFailedSinceLiveProvider] has latched: a session that has already
/// failed once is not made newly "connecting" by trying again on the same
/// backoff loop.
SyncStatus displaySyncStatus(SyncStatus status, bool hasFailedSinceLive) {
  if (status == SyncStatus.live || !hasFailedSinceLive) return status;
  return SyncStatus.offline;
}
