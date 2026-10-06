// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Who this account has blocked, held for as long as the session lasts.
///
/// The point of holding it here rather than beside the settings pane that
/// lists it: every read surface that has to hide a blocked author consults
/// this, and a set that lives only while one pane is mounted means nothing is
/// hidden anywhere else. That was the shape of the bug this replaces - the app
/// said "their messages are hidden for you" and nothing filtered anything.
///
/// The block list is a view filter, never a fetch filter. A blocked author's
/// messages still arrive and still land in the local database, and are dropped
/// where they would become UI. That is what makes unblocking instant and
/// complete: filtering them out of `/sync` instead would mean they never
/// arrive, and only a full channel reset could ever bring them back.
///
/// Two surfaces are out of reach from here and handled by the server for the
/// same reason. A reaction crosses the wire as a count with no reactor ids, so
/// there is nothing here to match on, and a push notification is on the device
/// before any of this runs. See `store/safety.rs`.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_data/data.dart';

import 'providers.dart';

/// The blocked ids, and whether they have been read back from the server yet.
class BlocksState {
  const BlocksState({this.ids = const {}, this.settled = false, this.error});

  /// Who is blocked, as far as this client knows.
  final Set<String> ids;

  /// Whether the server has been asked and has answered, either way. Kept apart
  /// from an empty [ids] because the two mean different things to a caller
  /// deciding what to show: "nobody is blocked" is an answer, and "not asked
  /// yet" is not.
  ///
  /// A failed fetch settles too, with [error] set and nothing blocked. That is a
  /// failure to filter and it is the right one of the two: a transcript held
  /// empty behind an unreachable block list is worse than an unfiltered one, and
  /// the settings pane says plainly that the list could not be read.
  final bool settled;

  /// Why the last fetch or change failed, for the one surface that lists them.
  final String? error;

  /// Whether [userId] is blocked. Null (an anonymized author) never is.
  bool contains(String? userId) => userId != null && ids.contains(userId);
}

class BlocksController extends StateNotifier<BlocksState> {
  BlocksController(this._ref) : super(const BlocksState()) {
    _account = _ref.read(sessionProvider).tokens?.userId;
    _sub = _ref.read(sessionProvider).changes.listen(_onSessionChanged);
    unawaited(refresh());
  }

  final Ref _ref;
  late final StreamSubscription<api.TokenPair?> _sub;

  /// Whose block list is held, so a session change that is only a token
  /// rotation is told apart from a different account signing in.
  String? _account;

  /// Bumped by every load and every session change, so an answer that is no
  /// longer the latest is dropped. A block or unblock does not bump it:
  /// dropping the whole answer for one edit left the rest of the list unloaded.
  int _generation = 0;

  /// What was blocked (true) or unblocked (false) since the load in flight
  /// began, laid over its answer so a `GET /blocks` sent before the change and
  /// answering after it cannot undo it.
  final Map<String, bool> _edits = {};

  /// Sign-out empties the set: the local database is one file for the whole
  /// app, so a block list outliving a sign-out would hide messages from
  /// whoever signs in next on this device.
  ///
  /// A non-null change is only refetched when the *account* changed. The
  /// session stream also fires on every automatic access-token rotation, and
  /// refetching on those turned routine rotation into a race against an
  /// in-flight block: a `GET /blocks` sent before the block landed, answering
  /// after it, would overwrite the set and silently unblock somebody the app
  /// had just confirmed as blocked.
  void _onSessionChanged(api.TokenPair? tokens) {
    if (tokens == null) {
      _generation++;
      _edits.clear();
      _account = null;
      state = const BlocksState();
      return;
    }
    if (tokens.userId == _account) return;
    _account = tokens.userId;
    _generation++;
    _edits.clear();
    state = const BlocksState();
    unawaited(refresh());
  }

  /// Reads the list back from the server, replacing what is held.
  ///
  /// Catches everything, not just [api.ApiException]: this runs unawaited from
  /// the constructor and from a session change, so anything that escapes it
  /// reaches no caller at all. An answer in a shape this client cannot parse is
  /// a list that could not be read, which is the same state as a refused one -
  /// and it must not take the app down on the way.
  Future<void> refresh() async {
    final generation = ++_generation;
    _edits.clear();
    try {
      final ids = (await _ref.read(apiProvider).listBlocks()).toSet();
      if (!mounted || generation != _generation) return;
      for (final MapEntry(:key, :value) in _edits.entries) {
        value ? ids.add(key) : ids.remove(key);
      }
      state = BlocksState(ids: ids, settled: true);
    } catch (error) {
      if (!mounted || generation != _generation) return;
      final message = error is api.ApiException ? error.message : '$error';
      state = BlocksState(ids: state.ids, settled: true, error: message);
    }
  }

  /// Blocks [userId], hiding them before the request answers so the transcript
  /// reacts to the tap rather than to the round trip, and putting them back if
  /// it fails.
  Future<void> block(String userId) => _change(userId, blocked: true);

  /// Unblocks [userId]. Rethrows, unlike [refresh]: unblocking is a deliberate
  /// action with a button behind it, and a failure that reaches nobody is how
  /// the old call site left somebody believing they had undone a block.
  Future<void> unblock(String userId) => _change(userId, blocked: false);

  Future<void> _change(String userId, {required bool blocked}) async {
    final before = state.ids;
    final after = {...before};
    if (blocked) {
      after.add(userId);
    } else {
      after.remove(userId);
    }
    _edits[userId] = blocked;
    state = BlocksState(ids: after, settled: state.settled);
    final client = _ref.read(apiProvider);
    try {
      if (blocked) {
        await client.blockUser(userId);
      } else {
        await client.unblockUser(userId);
      }
    } on api.ApiException {
      _edits.remove(userId);
      if (mounted) state = BlocksState(ids: before, settled: state.settled);
      rethrow;
    } catch (_) {
      // Not only ApiException: an unreverted change asserts a block never taken.
      _edits.remove(userId);
      if (mounted) state = BlocksState(ids: before, settled: state.settled);
      rethrow;
    }
  }

  @override
  void dispose() {
    unawaited(_sub.cancel());
    super.dispose();
  }
}

/// Deliberately not `autoDispose`: see this file's own notes. Every surface
/// that hides a blocked author reads it, so its lifetime is the session's.
final blocksProvider = StateNotifierProvider<BlocksController, BlocksState>(
  (ref) => BlocksController(ref),
);

/// A channel's transcript as it should be shown, beside what was really in it.
class VisibleTranscript {
  const VisibleTranscript({required this.messages, required this.newestSeq});

  /// The rows to render: everything the local store holds, minus blocked
  /// authors.
  final List<Message> messages;

  /// The highest seq of a delivered message in the channel, blocked authors
  /// included, or zero for a channel holding none.
  ///
  /// Read state has to keep counting them. A blocked author's message is hidden,
  /// not unreceived, and a marker that only advanced past what is shown would
  /// leave the channel lit as unread forever the moment they had the last word.
  ///
  /// KNOWN GAP, deliberately left: this filters against whatever is known, so a
  /// launch can paint a blocked author's message for the frames between the
  /// local store answering (fast, on disk) and `GET /blocks` answering (a round
  /// trip). Holding the transcript back until the block set settled was tried
  /// and reverted - it couples every channel's first paint to an unrelated
  /// network call. The real answer is a block set persisted beside the session,
  /// known synchronously at launch, with the fetch only correcting it.
  final int newestSeq;
}

/// Builds the transcript to render from the local store's rows.
///
/// A pure function with one call site rather than a provider wrapping the
/// stream, which is what this was first: a `StreamProvider.autoDispose.family`
/// watched from the screen thrashed create-and-dispose against drift's
/// deferred stream cleanup, and `pumpAndSettle` then never settled - which
/// hung `home_shell_test` and `router_recovery_test` and looked exactly like
/// CI being slow. The screen keeps its own long-lived subscription to
/// `watchChannel` and hands the rows here.
///
/// Filtering stays in one named place with the reasoning attached, which was
/// the point: what it is not any more is something a new render site gets for
/// free. A second transcript surface has to call this.
VisibleTranscript visibleTranscript(List<Message> rows, Set<String> blocked) {
  var newestSeq = 0;
  for (final message in rows) {
    if (!message.pending && message.seq > newestSeq) {
      newestSeq = message.seq;
    }
  }
  return VisibleTranscript(
    messages: rows
        .where((message) => !blocked.contains(message.authorId))
        .toList(growable: false),
    newestSeq: newestSeq,
  );
}
