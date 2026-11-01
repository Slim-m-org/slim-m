// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Which screen shares the viewer watches, and which one has their focus.
///
/// A share is keyed by its sharer: one person has at most one live share, and
/// the choice ends with it, so a new share from the same person is offered again.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_rtc/rtc.dart';

import 'voice_controller.dart';
import 'voice_flags.dart';

/// Sharers the viewer stopped watching, and the one share given the room.
class ShareWatchState {
  const ShareWatchState({
    this.stopped = const {},
    this.focused,
    this.held = const {},
  });

  final Set<String> stopped;
  final String? focused;

  /// Sharers kept unwatched by something other than the viewer's own choice,
  /// such as a direct-play player standing in for the share. A held sharer
  /// stays in [stopped] even while they are not sharing, so the share cannot
  /// be subscribed in the gap before it is stopped again.
  final Set<String> held;
}

/// Every watched sharer: the focused one first, then remote in roster order, then local.
List<VoiceParticipant> activeShares(
  List<VoiceParticipant> participants, {
  Set<String> stopped = const {},
  String? focusedIdentity,
}) {
  final remote = <VoiceParticipant>[];
  final local = <VoiceParticipant>[];
  for (final p in participants) {
    if (!p.isScreenSharing || stopped.contains(p.identity)) continue;
    (p.isLocal ? local : remote).add(p);
  }
  final all = [...remote, ...local];
  final focusAt = all.indexWhere((p) => p.identity == focusedIdentity);
  if (focusAt > 0) all.insert(0, all.removeAt(focusAt));
  return all;
}

/// The video-subscription keys for [stopped] shares.
Set<String> blockedShareKeys(Set<String> stopped) => {
  for (final id in stopped)
    videoSubscriptionKey(identity: id, screenShare: true),
};

class ShareWatchController extends StateNotifier<ShareWatchState> {
  ShareWatchController(this._applyBlocked) : super(const ShareWatchState());

  final void Function(Set<String> keys) _applyBlocked;

  void stop(String identity) {
    state = ShareWatchState(
      stopped: {...state.stopped, identity},
      focused: state.focused == identity ? null : state.focused,
      held: state.held,
    );
    _applyBlocked(blockedShareKeys(state.stopped));
  }

  void watch(String identity) {
    if (!state.stopped.contains(identity) && !state.held.contains(identity)) {
      return;
    }
    state = ShareWatchState(
      stopped: {...state.stopped}..remove(identity),
      focused: state.focused,
      held: {...state.held}..remove(identity),
    );
    _applyBlocked(blockedShareKeys(state.stopped));
  }

  /// Keeps [identity]'s share unwatched until [watch] gives it back.
  void hold(String identity) {
    state = ShareWatchState(
      stopped: {...state.stopped, identity},
      focused: state.focused == identity ? null : state.focused,
      held: {...state.held, identity},
    );
    _applyBlocked(blockedShareKeys(state.stopped));
  }

  /// Forgets every choice, for a call that has ended.
  void clear() {
    if (state.stopped.isEmpty && state.focused == null && state.held.isEmpty) {
      return;
    }
    final blocked = state.stopped.isNotEmpty;
    state = const ShareWatchState();
    if (blocked) _applyBlocked(const {});
  }

  /// A null [identity] returns to the grid.
  void focus(String? identity) => state = ShareWatchState(
    stopped: state.stopped,
    focused: identity,
    held: state.held,
  );

  /// Forgets choices about people who are no longer sharing.
  void prune(Set<String> sharing) {
    final stopped = state.stopped
        .where((id) => sharing.contains(id) || state.held.contains(id))
        .toSet();
    final focused = sharing.contains(state.focused) ? state.focused : null;
    if (stopped.length == state.stopped.length && focused == state.focused) {
      return;
    }
    final changed = stopped.length != state.stopped.length;
    state = ShareWatchState(
      stopped: stopped,
      focused: focused,
      held: state.held,
    );
    if (changed) _applyBlocked(blockedShareKeys(stopped));
  }
}

final shareWatchProvider =
    StateNotifierProvider<ShareWatchController, ShareWatchState>((ref) {
      final controller = ShareWatchController(
        (keys) => ref
            .read(voiceControllerProvider.notifier)
            .cameras
            .setVideoBlocked(keys),
      );
      // A dropped call reports an empty roster; the choices wait for the one after the rejoin.
      ref.listen<List<VoiceParticipant>>(voiceParticipantsProvider, (
        _,
        participants,
      ) {
        if (ref.read(voiceFlagsProvider).state != VoiceSessionState.connected) {
          return;
        }
        controller.prune({
          for (final p in participants)
            if (p.isScreenSharing) p.identity,
        });
      }, fireImmediately: true);
      ref.listen<String?>(
        voiceFlagsProvider.select((f) => f.channelId),
        (_, _) => controller.clear(),
      );
      return controller;
    });
