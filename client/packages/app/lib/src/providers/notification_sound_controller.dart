// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Plays a notification chime for the three kinds of event this client can
/// already see live: an incoming message, a voice roster changing while
/// connected, and an incoming DM call ring.
///
/// A message (or mention, or DM) and a call ring also fire a matching
/// [AppHaptics] cue on mobile - the platform's own real-time notification
/// moments, per the owner's own list - gated by the identical conditions the
/// sound itself already reads, since they ride the same call site rather
/// than a second copy of the rule.
///
/// The ring rides [dmCallRingControllerProvider]'s own `incoming` field
/// (the same one `IncomingCallOverlay` shows), not `dmCallActivityProvider`
/// - that provider answers a different question, "does this DM currently
/// have a call in progress" for `DmRow`'s own indicator, learned from
/// `Event::VoiceActivityChanged` (somebody's heartbeat), and a heartbeat is
/// not a ring: it fires the same way whether or not the callee was ever
/// notified, and stays set for as long as the call runs rather than for the
/// 30-second window a ring actually rings. Driving the chime from it meant a
/// call joined with no ring at all still played one, silently, with no
/// overlay to explain it, and a ring that reached the callee before the
/// caller's own room registered played nothing.
///
/// Wired at `HomeShell` (`ref.watch`, the same forced-instantiation shape
/// [blocksProvider] already uses) so it is created once for the signed-in
/// session rather than only while some particular screen happens to be
/// mounted, and torn down with the container rather than with any one route.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart' show AppHaptics;
import 'package:slimm_rtc/rtc.dart';

import '../audio/notification_sound.dart';
import 'dm_call_ring_controller.dart';
import 'live_events.dart';
import 'message_alert_policy.dart';
import 'notification_sound_rules.dart';
import 'notification_sound_settings.dart';
import 'providers.dart';
import 'voice_controller.dart';
import 'voice_settings_controller.dart' show voiceSettingsControllerProvider;

/// One of [AppHaptics]'s own static cues, injectable so a test can record a
/// call without a real haptic engine or platform channel - the same seam
/// [SoundPlayer] already gives this controller for the audio half.
typedef HapticsCue = void Function();

class NotificationSoundController {
  NotificationSoundController(
    this._ref, {
    SoundPlayer? player,
    HapticsCue? messageHaptic,
    HapticsCue? callRingHaptic,
  }) : _player = player ?? AudioPlayersSoundPlayer(),
       _messageHaptic = messageHaptic ?? AppHaptics.selection,
       _callRingHaptic = callRingHaptic ?? AppHaptics.impact {
    _messages = _ref.read(liveEventsProvider).listen(_onServerEvent);
    _voiceSub = _ref.listen<VoiceState>(
      voiceControllerProvider,
      _onVoiceStateChanged,
    );
    _ringSub = _ref.listen<IncomingDmCallRing?>(
      dmCallRingControllerProvider.select((s) => s.visibleIncoming),
      _onIncomingRingChanged,
    );
  }

  final Ref _ref;
  final SoundPlayer _player;
  final HapticsCue _messageHaptic;
  final HapticsCue _callRingHaptic;
  late final StreamSubscription<api.ServerEvent> _messages;
  late final ProviderSubscription<VoiceState> _voiceSub;
  late final ProviderSubscription<IncomingDmCallRing?> _ringSub;

  /// Who was already in the call the moment [voiceControllerProvider] last
  /// read [VoiceSessionState.connected], excluding this device's own
  /// identity - null whenever not connected. See [diffRoster]'s own doc
  /// comment for why null is what keeps the room's existing occupants from
  /// reading as a burst of live joins the moment this device arrives.
  Set<String>? _rosterBaseline;

  // --- Messages ---

  void _onServerEvent(api.ServerEvent event) {
    if (event case api.MessageCreated(:final message)) {
      unawaited(_onMessageCreated(message));
    }
  }

  Future<void> _onMessageCreated(api.Message message) async {
    if (!_ref.read(messageSoundSettingsProvider)) return;
    final alert = await _ref.read(messageAlertPolicyProvider).evaluate(message);
    if (alert == null) return;
    await _player.play(
      messageSoundKind(isDm: alert.isDm, mentionsSelf: alert.mentionsSelf),
    );
    _messageHaptic();
  }

  // --- Voice roster (member join/leave) and call failures (error) ---

  void _onVoiceStateChanged(VoiceState? previous, VoiceState next) {
    _handleVoiceError(previous, next);
    _handleRosterChange(previous, next);
  }

  void _handleVoiceError(VoiceState? previous, VoiceState next) {
    if (next.error == null || next.error == previous?.error) return;
    if (!_ref.read(messageSoundSettingsProvider)) return;
    unawaited(_player.play(NotificationSound.error));
  }

  /// [VoiceController] fans `states` and `participantChanges` in from two
  /// independent streams, so the event that flips [VoiceState.state] to
  /// [VoiceSessionState.connected] carries whatever stale `participants`
  /// list preceded it - the real roster arrives moments later on the other
  /// stream. Treating that first, empty-or-stale reading as the baseline
  /// would let the real roster, arriving right after it, read as a burst of
  /// live joins for everyone already in the room. [identical] below is what
  /// tells the two apart: the stale reading carries the exact same list
  /// instance, since nothing copied a new one into it.
  void _handleRosterChange(VoiceState? previous, VoiceState next) {
    if (next.state != VoiceSessionState.connected) {
      _rosterBaseline = null;
      return;
    }
    if (identical(next.participants, previous?.participants)) return;
    final selfId = _ref.read(apiProvider).session.tokens?.userId;
    final current = {
      for (final p in next.participants)
        if (p.identity != selfId) p.identity,
    };
    final diff = diffRoster(_rosterBaseline, current);
    _rosterBaseline = diff.baseline;
    if (diff.joined.isEmpty && diff.left.isEmpty) return;
    if (!_ref.read(voiceSettingsControllerProvider).joinLeaveSoundsEnabled) {
      return;
    }
    // +1 for this device's own presence, excluded from `current` above.
    if (current.length + 1 > soundsDisabledAboveParticipants) return;
    if (diff.joined.isNotEmpty) {
      unawaited(_player.play(NotificationSound.memberJoin));
    }
    if (diff.left.isNotEmpty) {
      unawaited(_player.play(NotificationSound.memberLeave));
    }
  }

  // --- An incoming DM call ---

  /// [DmCallRingController] already excludes this device's own outgoing
  /// ring (`callerId == selfId`) from ever becoming `incoming`, so the only
  /// guard left here is the same one the old activity-based version kept:
  /// never ring for a channel this device is already on.
  void _onIncomingRingChanged(
    IncomingDmCallRing? previous,
    IncomingDmCallRing? next,
  ) {
    if (next != null) {
      _startRinging(next);
    } else if (previous != null) {
      unawaited(_player.stopLoop());
    }
  }

  void _startRinging(IncomingDmCallRing ring) {
    if (!_ref.read(voiceSettingsControllerProvider).callRingSoundEnabled) {
      return;
    }
    if (ring.channelId == _ref.read(voiceControllerProvider).channelId) return;
    unawaited(_player.loop(NotificationSound.callRing));
    _callRingHaptic();
  }

  void dispose() {
    unawaited(_messages.cancel());
    _voiceSub.close();
    _ringSub.close();
    unawaited(_player.dispose());
  }
}

final notificationSoundControllerProvider =
    Provider<NotificationSoundController>((ref) {
      final controller = NotificationSoundController(ref);
      ref.onDispose(controller.dispose);
      return controller;
    });
