// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tells the server which channels this device has open and focused, so push
/// can skip a message the account is already reading here.
///
/// A device that is not in front of the user reports nothing: an unfocused
/// desktop window or a backgrounded phone must not silence the account's
/// other devices. The server lets a report lapse after 60 seconds, so while
/// anything is open it is re-sent well inside that, and again after every
/// reconnect, because a new socket starts with no report.
///
/// One per account container, started with its other services. Only the
/// account on screen reports: a Space out of view must neither claim channels
/// nor keep its server believing the user is active.
library;

import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/accounts/providers/account_slot.dart';
import 'app_lifecycle.dart';
import '../features/channels/providers/mounted_channels.dart';
import 'sync_controller.dart';

/// Comfortably inside the server's 60 second lapse.
const viewingRefreshInterval = Duration(seconds: 30);

/// How long after the last keyboard or pointer input this device reports its
/// user active; the server's own window is the same two minutes.
const activeInputWindow = Duration(minutes: 2);

/// Told about every keyboard or pointer input anywhere in the app.
abstract interface class InputListener {
  void noteInput();
}

class ViewingReporter implements InputListener {
  ViewingReporter(
    this._ref, {
    required void Function(Set<String> channels, bool active) send,
    Duration interval = viewingRefreshInterval,
  }) : _send = send,
       _interval = interval {
    _ref.read(mountedChannelsProvider).addListener(refresh);
  }

  final Ref _ref;
  final void Function(Set<String> channels, bool active) _send;
  final Duration _interval;
  Timer? _timer;
  DateTime? _lastInput;
  bool _reporting = false;

  bool get _focused =>
      _ref.read(appFocusedProvider) && _ref.read(accountActiveProvider);

  Set<String> _open() =>
      _focused ? _ref.read(mountedChannelsProvider).openChannelIds : const {};

  bool _recentInput() {
    final last = _lastInput;
    return last != null && clock.now().difference(last) < activeInputWindow;
  }

  bool _active() => _focused && _recentInput();

  /// Keyboard or pointer input on this device; marks it active for [activeInputWindow].
  @override
  void noteInput() {
    final wasRecent = _recentInput();
    _lastInput = clock.now();
    if (!wasRecent) refresh();
  }

  /// Reports now and restarts the refresh timer; call on anything that can
  /// change what is open, focused or active, or that gave the server a new socket.
  void refresh() {
    _timer?.cancel();
    final open = _open();
    final active = _active();
    final reporting = open.isNotEmpty || active;
    if (!reporting && !_reporting) return;
    _send(open, active);
    _reporting = reporting;
    if (reporting) {
      _timer = Timer.periodic(_interval, (_) => refresh());
    }
  }

  void dispose() {
    _timer?.cancel();
    _ref.read(mountedChannelsProvider).removeListener(refresh);
  }
}

/// The one pair of global input hooks, shared by every container's reporters.
class ViewingInput {
  ViewingInput._();

  static final instance = ViewingInput._();

  final _reporters = <InputListener>{};

  int get reporterCount => _reporters.length;

  void add(InputListener reporter) {
    if (_reporters.isEmpty) {
      GestureBinding.instance.pointerRouter.addGlobalRoute(_onPointer);
      HardwareKeyboard.instance.addHandler(_onKey);
    }
    _reporters.add(reporter);
  }

  void remove(InputListener reporter) {
    if (!_reporters.remove(reporter) || _reporters.isNotEmpty) return;
    GestureBinding.instance.pointerRouter.removeGlobalRoute(_onPointer);
    HardwareKeyboard.instance.removeHandler(_onKey);
  }

  void _onPointer(PointerEvent event) => _noteInput();

  bool _onKey(KeyEvent event) {
    _noteInput();
    return false;
  }

  void _noteInput() {
    for (final reporter in _reporters.toList()) {
      reporter.noteInput();
    }
  }
}

final viewingReporterProvider = Provider<ViewingReporter>((ref) {
  final reporter = ViewingReporter(
    ref,
    send: (channels, active) => ref
        .read(syncControllerProvider.notifier)
        .notifyViewing(channels, active: active),
  );
  ref.listen(appFocusedProvider, (_, _) => reporter.refresh());
  ref.listen(accountActiveProvider, (_, _) => reporter.refresh());
  ref.listen(syncControllerProvider, (_, status) {
    if (status == SyncStatus.live) reporter.refresh();
  });
  ViewingInput.instance.add(reporter);
  ref.onDispose(() {
    ViewingInput.instance.remove(reporter);
    reporter.dispose();
  });
  return reporter;
});
