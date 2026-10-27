// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The signed-in session: the held token pair and its change streams.
library;

import 'dart:async';

import 'logging/app_log.dart';
import 'logging/failure.dart';
import 'models.dart';

/// Holds the current session and hands out the access token.
///
/// Kept separate from the client so storage (secure storage on device, memory
/// in tests) can vary without the client knowing, and so a refresh performed by
/// one call is visible to every other.
class SessionStore {
  SessionStore({
    TokenPair? tokens,
    Future<void> Function(TokenPair?)? onChange,
    this.sync,
  })  : _tokens = tokens,
        _onChange = onChange;

  /// How this session coordinates with other tabs sharing its storage; null where one process owns it.
  final SessionSync? sync;

  TokenPair? _tokens;
  final Future<void> Function(TokenPair?)? _onChange;

  /// Chains every [_onChange] call behind the last, so a slow write cannot
  /// finish after a faster later one and leave a stale value stored: without
  /// it, a rotation overtaking the sign-out that superseded it persists a
  /// token for a session that has ended.
  Future<void> _pending = Future<void>.value();

  final _changes = StreamController<TokenPair?>.broadcast();

  /// Emits whenever the session changes, including null when it ends.
  Stream<TokenPair?> get changes => _changes.stream;

  TokenPair? get tokens => _tokens;
  bool get isSignedIn => _tokens != null;

  /// In-memory and announced immediately, same as always: nothing here
  /// depends on [_onChange], so a slow or hung persist layer never delays a
  /// live session from working. [settled] is the separate, explicit way to
  /// wait for durability.
  void set(TokenPair? tokens) {
    _tokens = tokens;
    _changes.add(tokens);
    if (_onChange case final onChange?) {
      // Caught, or an uncaught error here would poison every later onChange (see FileKeyStore).
      _pending = _pending.then((_) => onChange(tokens)).catchError(ignoreError(
          LogTag.net, 'A listener for session changes threw; ignoring it'));
    }
  }

  /// The [lastEndReason] of a sign-out the person asked for themselves.
  static const signedOutByUser = 'signed out';

  /// Whether the session last ended without the person asking: a refresh the
  /// server rejected, for instance after another device signed this one out.
  bool get endedByServer =>
      _lastEndReason != null && _lastEndReason != signedOutByUser;

  /// Ends the session. [reason] is recorded on [lastEndReason] and announced
  /// on [endings] so the app can say *why* somebody was signed out - the one
  /// thing a person who has just been thrown back to the sign-in screen
  /// cannot otherwise find out.
  void clear({String reason = signedOutByUser}) {
    _lastEndReason = reason;
    _endings.add(reason);
    set(null);
  }

  String? _lastEndReason;
  final _endings = StreamController<String>.broadcast();

  DateTime? _lastRotationAt;
  bool _lastRotationPersisted = false;

  /// Records that a refresh rotation completed, and whether its new pair
  /// reached storage before [settled]'s deadline. Only [describeRejection]
  /// reads this.
  void noteRotation({required bool persisted}) {
    _lastRotationAt = DateTime.now();
    _lastRotationPersisted = persisted;
  }

  /// Why a refresh was just rejected, in the terms that separate the
  /// candidate causes rather than the terms the server used.
  ///
  /// A rejection on a pair this process never rotated means what was loaded
  /// from storage at launch was already dead: a write that never landed, or
  /// another instance that spent it. A rejection seconds after a rotation
  /// means this process raced itself or lost the response. Those want
  /// different fixes and are indistinguishable from the sign-in screen, which
  /// is the only thing anybody sees today.
  String describeRejection() {
    final at = _lastRotationAt;
    if (at == null) {
      return 'credentials rejected; the stored pair was already spent at launch';
    }
    final age = DateTime.now().difference(at).inSeconds;
    final durable = _lastRotationPersisted ? 'persisted' : 'NOT persisted';
    return 'credentials rejected ${age}s after a rotation that was $durable';
  }

  /// Why the session last ended, or null if it never has in this process.
  String? get lastEndReason => _lastEndReason;

  /// Emits the reason each time the session ends. Separate from [changes],
  /// which reports every token rotation too.
  Stream<String> get endings => _endings.stream;

  /// Resolves once every [_onChange] triggered by [set] so far has settled,
  /// whether it succeeded or failed.
  ///
  /// [SlimmApiAuth._refreshOnce] awaits this after rotating: the server has
  /// already spent the old refresh token by the time a new one comes back, so
  /// a process death between that response and the new token reaching disk
  /// replays the old, now-spent one on the next launch and gets read as
  /// reuse. Awaiting this closes that window down to the write itself.
  ///
  /// It never completes before the write does, so anything awaiting it
  /// inherits the key store's worst case and must bound its own wait. A
  /// failed write is fine and resolves normally; only a hung one is a
  /// problem, and every 401 retry funnels through that same rotation.
  Future<void> get settled => _pending;

  Future<void> dispose() => Future.wait([_changes.close(), _endings.close()]);

  /// Takes up the pair another tab stored, or its sign-out.
  ///
  /// Memory only: the other tab already wrote it, and writing it back would
  /// race that tab's next rotation.
  void adopt(TokenPair? tokens, {String reason = 'signed out in another tab'}) {
    _tokens = tokens;
    if (tokens == null) _endings.add(reason);
    _changes.add(tokens);
  }

  /// Re-reads shared storage after another tab wrote to it.
  Future<void> reloadFromStorage() async {
    await adoptStoredRotation(adoptSignOut: true);
  }

  /// Adopts the stored pair when it is not the one held, returning it.
  ///
  /// Null means this tab still holds the newest pair and must rotate itself.
  Future<TokenPair?> adoptStoredRotation({bool adoptSignOut = false}) async {
    final source = sync;
    final held = _tokens;
    if (source == null || held == null) return null;
    await settled;
    final TokenPair? stored;
    try {
      stored = await source.readStored();
    } on Object catch (error, stack) {
      AppLog.swallowed(
          LogTag.net, 'Could not read the shared session', error, stack);
      return null;
    }
    if (!identical(_tokens, held)) return null;
    if (stored == null) {
      if (adoptSignOut) adopt(null);
      return null;
    }
    if (stored.refreshToken == held.refreshToken) return null;
    adopt(stored);
    return stored;
  }
}

/// What a [SessionStore] needs when other tabs share its stored token pair.
///
/// Each tab holds its own in-memory pair, so a rotation in one leaves the
/// others on a refresh token the server has already spent.
abstract interface class SessionSync {
  /// Runs [body] while no other tab runs one, so only one tab rotates at a time.
  Future<T> exclusive<T>(Future<T> Function() body);

  /// The pair currently in shared storage, or null once a tab has signed out.
  Future<TokenPair?> readStored();
}
