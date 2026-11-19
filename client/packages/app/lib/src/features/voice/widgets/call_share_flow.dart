// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The call row's screen share: start, stop and change source, one request at
/// a time, with the ceiling and audio choice Voice settings already saved.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart' show ScreenShareSource, VoiceSessionState;

import '../providers/voice_controller.dart';
import '../providers/voice_flags.dart';
import '../providers/voice_settings_controller.dart'
    show voiceSettingsControllerProvider;
import 'screen_share_start.dart';

class CallShareFlow {
  CallShareFlow({
    required this.ref,
    required this.controller,
    required this.voice,
    required this.mounted,
    required this.changed,
  });

  final WidgetRef ref;
  final VoiceController Function() controller;

  /// The call as the row last drew it, read again after every await.
  final VoiceFlags Function() voice;
  final bool Function() mounted;

  /// Rebuilds the row after running the given state change.
  final void Function(VoidCallback mutate) changed;

  /// The share button, which the source picker rests above.
  final buttonKey = GlobalKey();

  /// Guards a fast double-tap from opening two source-selection sheets: the
  /// enumeration and its own sheet run entirely inside [_start], before
  /// `VoiceScreenShare.setScreenShare` is ever called, so nothing further down
  /// the stack can catch a re-entrant tap.
  bool _inFlight = false;

  /// Whichever source [_start] last resolved a picker's choice to -
  /// preselected (never silently reused) the next time the picker opens, so
  /// report 2's "always goes back to whatever was just chosen" reads as a
  /// highlighted default instead of nothing worth remembering at all. Reset
  /// by nothing on purpose: it only ever changes what a fresh sheet opens
  /// pointing at, never whether one opens.
  String? _lastSourceId;
  ScreenShareSource? _lastSource;

  ScreenShareSource? get lastSource => _lastSource;

  /// Stops a live or requested share (which also ends the recording), or starts one; [changeSource] is the menu's route to a new source, so a bare tap never has to guess which was meant.
  void toggle(BuildContext context) {
    if (_inFlight) return;
    unawaited(_toggle(context));
  }

  void changeSource(BuildContext context) {
    if (_inFlight) return;
    unawaited(_changeSource(context));
  }

  /// Replaces the running share with [source], picked from the menu.
  void pick(BuildContext context, ScreenShareSource source) {
    if (_inFlight) return;
    unawaited(_start(context, stopFirst: true, preset: source));
  }

  Future<void> _toggle(BuildContext context) async {
    final voice = this.voice();
    if (voice.screenSharing || voice.awaitingBroadcast) {
      await controller().share.setScreenShare(false);
      return;
    }
    await _start(context);
  }

  /// Report 2 in the backlog channel, in the owner's own words: "after
  /// choosing a screen share screen there is never an option to choose a
  /// different one while in the same call" - reached from the share button's
  /// options caret (or a long press) while it is active, since a bare tap
  /// there is already spoken for by stop. Stops the running share
  /// outright before asking for a new source, rather than trusting
  /// [VoiceSession.setScreenShareEnabled] to hot-swap a capture already in
  /// flight - the same two-step "stop, then start" a person switching
  /// sources by hand would do themselves.
  Future<void> _changeSource(BuildContext context) async {
    if (!voice().screenSharing) return;
    final controller = this.controller();
    if (!controller.video.screenShareSourcePickerUseful) {
      await controller.share.setScreenShare(false);
      if (!context.mounted) return;
      await _start(context);
      return;
    }
    await _start(context, stopFirst: true);
  }

  /// A zero-height strip on the share button's top edge, so the picker rests above the dock.
  Rect? _pickerAnchor() {
    final box = buttonKey.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.attached) return null;
    final top = box.localToGlobal(Offset.zero);
    return Rect.fromLTWH(top.dx, top.dy - AppSpacing.s8, box.size.width, 0);
  }

  Future<void> _start(
    BuildContext context, {
    bool stopFirst = false,
    ScreenShareSource? preset,
  }) async {
    final controller = this.controller();
    changed(() => _inFlight = true);
    try {
      // The saved ceiling and audio choice, applied directly rather than asked again.
      final settings = ref.read(voiceSettingsControllerProvider);
      final quality = settings.screenShareQuality;

      final pick = preset != null
          ? (proceed: true, id: preset.id, source: preset)
          : await pickShareSource(
              context,
              controller,
              lastSourceId: _lastSourceId,
              anchorRect: _pickerAnchor(),
            );
      if (!pick.proceed) return;
      final sourceId = pick.id;
      // The call can end while a picker or the source list is open.
      final voice = this.voice();
      if (!mounted() ||
          !(voice.state == VoiceSessionState.connected || voice.rejoining)) {
        return;
      }
      _lastSourceId = sourceId ?? _lastSourceId;
      _lastSource = pick.source ?? _lastSource;
      if (stopFirst) await controller.share.setScreenShare(false);
      await controller.share.setScreenShare(
        true,
        quality: quality,
        sourceId: sourceId,
        includeAudio: settings.screenShareIncludeAudio,
        maxHeight: await screenShareCeiling(ref),
        source: pick.source,
      );
    } finally {
      if (mounted()) changed(() => _inFlight = false);
    }
  }
}
