// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The caller's own private note about one other account: the per-subject
/// sibling of `channelPermissionsProvider`'s per-channel bitmask, and the
/// same shape for the same reason - nothing here is long-lived state, so a
/// sheet refetches on entry rather than the app holding every note it has
/// ever looked at in memory.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart';

import '../../../providers/providers.dart';

/// The caller's own note about [subjectId], fetched fresh on every watch.
/// `body` and `updatedAt` both null means the caller has left no note about
/// this subject - the wire's own "nothing here" shape (`GET
/// /users/{userId}/note`), not a sentinel this provider invents.
final userNoteProvider = FutureProvider.autoDispose.family<UserNote, String>(
  (ref, subjectId) => ref.watch(apiProvider).getUserNote(subjectId),
);
