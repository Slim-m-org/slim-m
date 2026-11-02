// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The one-time hints the call dock shows next to a control: which microphone
/// a call just opened, and that the share button holds options on a phone.
///
/// A hint is remembered on this device once it has been on screen, so it comes
/// back only when it says something new: the saved microphone changed, or
/// never has been shown.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_rtc/rtc.dart' show resolveAudioDevice;

import '../../../providers/providers.dart';
import 'muted_talk_cue.dart';
import 'voice_controller.dart';
import 'voice_settings_controller.dart' show savedAudioInputId;

/// The microphone the person last saw named; empty text is the system default.
const micCueSeenKey = 'slimm.voice.mic_cue_device';

const shareHintSeenKey = 'slimm.voice.share_hint_seen';

const shareHintText = 'Hold to change share quality';

enum DockHintTarget { mic, share }

class DockHint {
  const DockHint({
    required this.target,
    required this.text,
    required this.seenKey,
    required this.seenValue,
  });

  final DockHintTarget target;
  final String text;

  /// Written once the hint has been shown, so it is not shown again.
  final String seenKey;
  final Object seenValue;

  Future<void> remember(SharedPreferences prefs) async {
    final value = seenValue;
    if (value is bool) {
      await prefs.setBool(seenKey, value);
    } else {
      await prefs.setString(seenKey, value as String);
    }
  }
}

/// Bumped when a hint is remembered, so the other anchors choose again.
final dockHintEpochProvider = StateProvider<int>((ref) => 0);

/// The hint to show now, or null. [touch] is the dock's width-derived density.
///
/// A plain async function over the container, not an auto-disposed provider:
/// two anchors ask once each as a call's dock mounts and again when a hint is
/// remembered, and nothing needs to outlive them.
Future<DockHint?> resolveDockHint(
  ProviderContainer container, {
  required bool touch,
}) async {
  final prefs = await container.read(preferencesProvider.future);
  if (container.read(mutedTalkCueProvider)) return _MutedTalkHint(container);
  final mic = await _micCue(container, prefs);
  if (mic != null) return mic;
  if (!touch || prefs.getBool(shareHintSeenKey) == true) return null;
  return const DockHint(
    target: DockHintTarget.share,
    text: shareHintText,
    seenKey: shareHintSeenKey,
    seenValue: true,
  );
}

Future<DockHint?> _micCue(
  ProviderContainer container,
  SharedPreferences prefs,
) async {
  final devices = container.read(voiceControllerProvider.notifier).devices;
  if (!devices.supportsAudioInputSelection) return null;
  final saved = savedAudioInputId(prefs);
  final listed = await devices.audioInputDevices();
  final resolved = resolveAudioDevice(listed, saved);
  // A saved microphone that is not listed falls back to the default at join; an empty list says nothing.
  final fellBack = saved != null && resolved == null && listed.isNotEmpty;
  final current = fellBack ? 'missing:$saved' : (resolved?.id ?? '');
  if (prefs.getString(micCueSeenKey) == current) return null;
  final label = resolved?.label ?? '';
  final name = label.isEmpty ? 'System default' : label;
  return DockHint(
    target: DockHintTarget.mic,
    text: fellBack ? 'Mic: $name (saved mic not found)' : 'Mic: $name',
    seenKey: micCueSeenKey,
    seenValue: current,
  );
}

/// The talking-while-muted cue: never remembered, it ends when it has been seen.
class _MutedTalkHint extends DockHint {
  _MutedTalkHint(this._container)
    : super(
        target: DockHintTarget.mic,
        text: mutedTalkCueText,
        seenKey: 'muted-talk',
        seenValue: true,
      );

  final ProviderContainer _container;

  @override
  Future<void> remember(SharedPreferences prefs) async {
    _container.read(mutedTalkCueProvider.notifier).state = false;
  }
}
