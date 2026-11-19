// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The call panel on the overlay runner (decision 0096): the monitor it is on,
/// and only what changed sent to it.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_platform/platform.dart';
import 'package:slimm_rtc/rtc.dart' show VoiceParticipant;

import '../../voice/providers/voice_flags.dart';
import '../../voice/providers/voice_settings_controller.dart';
import 'call_overlay_avatar.dart';
import 'call_overlay_panel.dart';

class CallOverlayPanelSync {
  CallOverlayPanelSync(
    this._ref,
    this._window, {
    required bool Function() windows,
    required bool Function() mounted,
    required OverlaySupport Function() support,
  }) : _windows = windows,
       _mounted = mounted,
       _support = support;

  final Ref _ref;
  final ScreenOverlay _window;

  /// Windows gives the panel its own window; on Linux it shares the overlay's.
  final bool Function() _windows;
  final bool Function() _mounted;
  final OverlaySupport Function() _support;
  bool _up = false;
  int _monitor = 0;
  OverlayPanel? _last;
  final _avatarWatches =
      <OverlayAvatarWho, ProviderSubscription<AsyncValue<OverlayAvatar>>>{};
  // The picture key the runner holds per user id, so a picture crosses the channel once.
  final _avatarsSent = <String, String>{};

  /// Whether the panel is on screen.
  bool get up => _up;

  Future<void> start() async {
    final monitor = callOverlayMonitor(
      _support(),
      await _window.appMonitor(),
      chosen: _ref.read(voiceSettingsControllerProvider).callOverlayScreen,
    );
    if (!_windows() && !await _window.show([monitor])) return;
    if (!_mounted()) return;
    _monitor = monitor;
    forget();
    _up = true;
  }

  Future<void> stop() async {
    forget();
    await (_windows() ? _window.panel(null) : _window.hide());
  }

  /// A new or closed window holds none of what was sent before, so nothing is assumed sent.
  void forget() {
    _up = false;
    _last = null;
    _avatarsSent.clear();
    for (final watch in _avatarWatches.values) {
      watch.close();
    }
    _avatarWatches.clear();
  }

  /// Sends the panel only when what it says changed, so a speaking flicker that changes no row costs nothing.
  void sync() {
    if (!_up || !_mounted()) return;
    final participants = _ref.read(voiceParticipantsAtOnce);
    final panel = callOverlayPanel(
      participants,
      monitor: _monitor,
      corner: _ref.read(voiceSettingsControllerProvider).callOverlayCorner,
      avatars: _watchAvatars(callOverlayShown(participants)),
    );
    if (panel == _last) return;
    _last = panel;
    unawaited(_window.panel(_picturesOnce(panel)));
  }

  /// Follows the shown people's pictures, so one arriving or changing repaints the panel.
  Map<String, OverlayAvatar> _watchAvatars(List<VoiceParticipant> shown) {
    final wanted = {for (final p in shown) (id: p.identity, name: p.name)};
    _avatarWatches.keys
        .where((who) => !wanted.contains(who))
        .toList()
        .forEach((who) => _avatarWatches.remove(who)?.close());
    for (final who in wanted) {
      _avatarWatches.putIfAbsent(
        who,
        () => _ref.listen(callOverlayAvatarProvider(who), (_, _) => sync()),
      );
    }
    return {
      for (final entry in _avatarWatches.entries)
        if (entry.value.read().valueOrNull case final avatar?)
          entry.key.id: avatar,
    };
  }

  OverlayPanel _picturesOnce(OverlayPanel panel) => panel.withRows([
    for (final row in panel.rows)
      if (row.avatarKey == null || _avatarsSent[row.id] == row.avatarKey)
        row.withoutAvatarBytes()
      else
        _markSent(row),
  ]);

  OverlayPanelRow _markSent(OverlayPanelRow row) {
    _avatarsSent[row.id] = row.avatarKey!;
    return row;
  }
}
