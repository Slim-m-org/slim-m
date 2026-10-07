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
/// Read once from bootstrap, beside the sync and push controllers, so it is
/// never built by a widget test that has no socket to report over.
library;

import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_lifecycle.dart';
import 'mounted_channels.dart';
import 'sync_controller.dart';

/// Comfortably inside the server's 60 second lapse.
const viewingRefreshInterval = Duration(seconds: 30);

/// How long after the last keyboard or pointer input this device reports its
/// user active; the server's own window is the same two minutes.
const activeInputWindow = Duration(minutes: 2);

class ViewingReporter {
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
  Timer? _inputLapse;
  bool _recentInput = false;
  bool _reporting = false;

  bool get _focused => _ref.read(appFocusedProvider);

  Set<String> _open() =>
      _focused ? _ref.read(mountedChannelsProvider).openChannelIds : const {};

  bool _active() => _focused && _recentInput;

  /// Keyboard or pointer input on this device; marks it active for [activeInputWindow].
  void noteInput() {
    _inputLapse?.cancel();
    _inputLapse = Timer(activeInputWindow, () {
      _recentInput = false;
      refresh();
    });
    if (_recentInput) return;
    _recentInput = true;
    refresh();
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
      _timer = Timer.periodic(_interval, (_) => _send(_open(), _active()));
    }
  }

  void dispose() {
    _timer?.cancel();
    _inputLapse?.cancel();
    _ref.read(mountedChannelsProvider).removeListener(refresh);
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
  ref.listen(syncControllerProvider, (_, status) {
    if (status == SyncStatus.live) reporter.refresh();
  });
  void onPointer(PointerEvent event) => reporter.noteInput();
  bool onKey(KeyEvent event) {
    reporter.noteInput();
    return false;
  }

  GestureBinding.instance.pointerRouter.addGlobalRoute(onPointer);
  HardwareKeyboard.instance.addHandler(onKey);
  ref.onDispose(() {
    GestureBinding.instance.pointerRouter.removeGlobalRoute(onPointer);
    HardwareKeyboard.instance.removeHandler(onKey);
    reporter.dispose();
  });
  return reporter;
});
