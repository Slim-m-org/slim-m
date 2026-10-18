// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Owns one container per account and decides which one is on screen.
/// See docs/decisions/0068-multiple-servers-in-one-app.md.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_rtc/rtc.dart';

import '../../../diagnostics/debug_log.dart';
import '../../../providers/providers.dart'
    show sessionProvider, sessionRestoreNoteProvider;
import '../../messages/providers/attachment_preview_bytes.dart';
import '../../voice/providers/voice_controller.dart';
import '../../voice/providers/voice_flags.dart';
import 'account.dart';
import 'account_slot.dart';
import 'account_store.dart';
import 'account_unread.dart';

/// One account's container with the live facts the switcher shows about it.
class AccountRuntime {
  AccountRuntime(this.slot, this.container);

  final AccountSlot slot;
  final ProviderContainer container;
  AccountUnread unread = AccountUnread.none;
  bool inCall = false;
  bool signedIn = false;
  final List<void Function()> _cancels = [];

  Account? get account => slot.account;
}

typedef RuntimeHook = Future<void> Function(AccountRuntime runtime);

class AccountHost extends ChangeNotifier {
  AccountHost({
    required this.store,
    required this.createContainer,
    required this.startServices,
    required this.onActivate,
    required this.readSession,
    required this.signOutRuntime,
  });

  final AccountStore store;
  final ProviderContainer Function(AccountSlot slot) createContainer;

  /// Brings a container's sync, push and notifiers up without a window.
  final RuntimeHook startServices;

  /// Re-reads the shared preferences a container cached before it was shown.
  final RuntimeHook onActivate;

  /// Restores the account's stored session into its container.
  final Future<bool> Function(AccountRuntime runtime) readSession;

  /// Ends the session on the server and clears it locally.
  final Future<void> Function(AccountRuntime runtime) signOutRuntime;

  final List<AccountRuntime> _runtimes = [];
  AccountRuntime? _active;
  AccountRuntime? _returnTo;
  AccountIndex _index = const AccountIndex();
  bool _disposed = false;

  AccountRuntime? get active => _active;

  /// Runtimes that have a server; an add flow before its server is chosen has none.
  List<AccountRuntime> get accounts => [
    for (final r in _runtimes)
      if (r.account != null) r,
  ];

  bool get adding => _returnTo != null;

  /// Backing out of the add flow needs somewhere to land.
  bool get canCancelAdd => _returnTo != null;

  /// The account other than the active one that is in a call, if any.
  AccountRuntime? get callElsewhere {
    for (final r in _runtimes) {
      if (r.inCall && r != _active) return r;
    }
    return null;
  }

  /// The account that is in a call, on screen or not.
  AccountRuntime? get callRuntime {
    for (final r in _runtimes) {
      if (r.inCall) return r;
    }
    return null;
  }

  AccountRuntime? runtimeFor(String origin) {
    for (final r in _runtimes) {
      if (r.account?.origin == origin) return r;
    }
    return null;
  }

  /// A slot whose server choices are filed with this host.
  AccountSlot newSlot([Account? account]) =>
      AccountSlot(account: account, chooseServer: _fileServer);

  /// Builds the first container, which main shows while the rest start.
  ProviderContainer createFirst() {
    final slot = newSlot();
    final container = createContainer(slot);
    adoptFirst(container, slot);
    return container;
  }

  /// Registers the container [main] already built, before any account is known.
  AccountRuntime adoptFirst(ProviderContainer container, AccountSlot slot) {
    final runtime = _track(AccountRuntime(slot, container));
    _active = runtime;
    return runtime;
  }

  /// Loads the index, gives the first container the active account, and brings
  /// up the rest in the background.
  Future<void> start() async {
    try {
      _index = await store.loadOrMigrate();
    } catch (_) {
      _index = const AccountIndex();
    }
    final first = _active;
    final account = _index.active;
    if (first == null || account == null) return;
    first.slot.account = account;
    await readSession(first);
    _watch(first);
    for (final other in _index.accounts) {
      if (other.origin == account.origin) continue;
      unawaited(_startBackground(other));
    }
    _changed();
  }

  Future<void> _startBackground(Account account) async {
    if (_disposed) return;
    final slot = newSlot(account);
    final runtime = _track(AccountRuntime(slot, createContainer(slot)));
    runtime.container.read(accountActiveProvider.notifier).state = false;
    await readSession(runtime);
    await startServices(runtime);
    _watch(runtime);
    _changed();
  }

  AccountRuntime _track(AccountRuntime runtime) {
    _runtimes.add(runtime);
    return runtime;
  }

  /// A server was chosen in a container; files it, replacing an unused account.
  Account _fileServer(AccountSlot slot, Uri server) {
    final origin = originOf(server);
    final existing = _index.byOrigin(origin);
    final runtime = _runtimeOf(slot);
    final previous = slot.account;
    if (previous != null && !(runtime?.signedIn ?? false)) {
      _index = _index.without(previous.origin);
    }
    final account = existing ?? Account.forServer(server);
    _index = _index.withAccount(account);
    if (runtime != null && existing != null) {
      // Already filed here: land on that account, not on a duplicate.
      scheduleMicrotask(() => _mergeInto(runtime, origin));
    } else {
      scheduleMicrotask(() => _watchLate(slot));
    }
    unawaited(_saveIndex());
    return account;
  }

  AccountRuntime? _runtimeOf(AccountSlot slot) {
    for (final r in _runtimes) {
      if (r.slot == slot) return r;
    }
    return null;
  }

  void _watchLate(AccountSlot slot) {
    final runtime = _runtimeOf(slot);
    if (runtime != null) _watch(runtime);
    _changed();
  }

  void _mergeInto(AccountRuntime duplicate, String origin) {
    duplicate.slot.account = null;
    final target = runtimeFor(origin);
    if (target == null) return;
    unawaited(switchTo(origin));
    _retire(duplicate);
  }

  void _watch(AccountRuntime runtime) {
    if (runtime._cancels.isNotEmpty) return;
    final container = runtime.container;
    final session = container.read(sessionProvider);
    runtime.signedIn = session.isSignedIn;
    final changes = session.changes.listen((tokens) {
      runtime.signedIn = tokens != null;
      _changed();
    });
    runtime._cancels.add(changes.cancel);
    // See SessionStore.describeRejection for why a sign-out needs a reason.
    final endings = session.endings.listen(
      (reason) =>
          container.read(debugLogProvider.notifier).record('session', reason),
    );
    runtime._cancels.add(endings.cancel);
    final restoreNotes = container.listen<String?>(sessionRestoreNoteProvider, (
      _,
      note,
    ) {
      if (note != null) {
        container.read(debugLogProvider.notifier).record('session', note);
      }
    });
    runtime._cancels.add(restoreNotes.close);

    final unread = container.listen<AsyncValue<AccountUnread>>(
      accountUnreadProvider,
      (_, next) {
        final value = next.valueOrNull ?? AccountUnread.none;
        if (value == runtime.unread) return;
        runtime.unread = value;
        _changed();
      },
      fireImmediately: true,
    );
    runtime._cancels.add(unread.close);

    final voice = container.listen<VoiceFlags>(voiceFlagsProvider, (_, next) {
      final live = next.state == VoiceSessionState.connected || next.rejoining;
      if (live == runtime.inCall) return;
      runtime.inCall = live;
      if (live) _leaveOtherCalls(runtime);
      _changed();
    }, fireImmediately: true);
    runtime._cancels.add(voice.close);
  }

  void _leaveOtherCalls(AccountRuntime joined) {
    for (final other in _runtimes) {
      if (other == joined || !other.inCall) continue;
      unawaited(other.container.read(voiceControllerProvider.notifier).leave());
    }
  }

  /// Puts [origin]'s account on screen.
  Future<void> switchTo(String origin) async {
    final next = runtimeFor(origin);
    if (next == null) return;
    await _activate(next);
    _returnTo = null;
    _changed();
  }

  Future<void> _activate(AccountRuntime next) async {
    final previous = _active;
    if (previous == next) return;
    previous?.container.read(accountActiveProvider.notifier).state = false;
    next.container.read(accountActiveProvider.notifier).state = true;
    _active = next;
    if (next.slot.restoreFailed) await readSession(next);
    await onActivate(next);
    if (next.account != null) {
      _index = _index.withActive(next.account!.origin);
      unawaited(_saveIndex());
    }
    _changed();
  }

  /// Mounts an empty container at onboarding; sign-in runs unchanged inside it.
  Future<void> beginAdd() async {
    final current = _active;
    if (current == null) return;
    final slot = newSlot();
    final runtime = _track(AccountRuntime(slot, createContainer(slot)));
    await startServices(runtime);
    _returnTo = current;
    await _activate(runtime);
  }

  /// Leaves the add flow, dropping its account if it never signed in.
  Future<void> cancelAdd() async {
    final back = _returnTo;
    final pending = _active;
    if (back == null || pending == null) return;
    _returnTo = null;
    await _activate(back);
    await _discardIfUnused(pending);
  }

  Future<void> _discardIfUnused(AccountRuntime pending) async {
    if (pending.signedIn) return;
    final account = pending.account;
    if (account != null) {
      _index = _index.without(account.origin);
      await _saveIndex();
    }
    _retire(pending);
  }

  /// Ends the session on the server and, when another account remains,
  /// removes this one from the list.
  Future<void> signOut(String origin) async {
    final runtime = runtimeFor(origin);
    final account = runtime?.account;
    if (runtime == null || account == null) return;
    if (runtime.signedIn) await signOutRuntime(runtime);
    if (accounts.length <= 1) return;
    await removeAccount(origin);
  }

  /// Takes this account out of the list and forgets its session.
  Future<void> removeAccount(String origin) async {
    final runtime = runtimeFor(origin);
    final account = runtime?.account;
    if (runtime == null || account == null) return;
    final others = accounts.where((r) => r != runtime).toList();
    _index = _index.without(origin);
    try {
      await store.deleteSession(account);
    } catch (_) {
      // A store that refuses the delete leaves a stale entry, never a signed-in ghost.
    }
    await _saveIndex();
    if (_active == runtime) {
      if (others.isNotEmpty) {
        await _activate(others.first);
      } else {
        await beginFresh();
      }
    }
    await clearAttachmentPreviews(
      runtime.container.read(attachmentPreviewCacheProvider),
      Uri.parse(origin),
    );
    _retire(runtime);
  }

  /// An empty first-run container, for when the last account is removed.
  Future<void> beginFresh() async {
    final slot = newSlot();
    final runtime = _track(AccountRuntime(slot, createContainer(slot)));
    await startServices(runtime);
    await _activate(runtime);
  }

  void _retire(AccountRuntime runtime) {
    _runtimes.remove(runtime);
    for (final cancel in runtime._cancels) {
      cancel();
    }
    runtime._cancels.clear();
    // After the frame that stops showing it, so no widget reads a closed container.
    SchedulerBinding.instance.addPostFrameCallback(
      (_) => runtime.container.dispose(),
    );
    SchedulerBinding.instance.ensureVisualUpdate();
    _changed();
  }

  Future<void> _saveIndex() async {
    try {
      await store.save(_index);
    } catch (_) {
      // Best effort: the sessions themselves are what matter, and each is saved on its own.
    }
  }

  bool _notifyQueued = false;

  /// Deferred a microtask, because a container's listeners can fire while the
  /// widget tree is building and a listener must not mark that tree dirty.
  void _changed() {
    if (_disposed || _notifyQueued) return;
    _notifyQueued = true;
    scheduleMicrotask(() {
      _notifyQueued = false;
      if (!_disposed) notifyListeners();
    });
  }

  @override
  void dispose() {
    _disposed = true;
    for (final r in _runtimes) {
      for (final cancel in r._cancels) {
        cancel();
      }
    }
    super.dispose();
  }

  @visibleForTesting
  String debugIndexJson() => jsonEncode(_index.toJson());
}
