// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Watches the input gate while the mic is muted and raises the dock's
/// talking-while-muted cue, so a muted member learns it before anyone asks.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_rtc/rtc.dart' show VoiceSessionState;

import '../providers/muted_talk_cue.dart';
import '../providers/call_dock_hint.dart' show dockHintEpochProvider;
import '../providers/voice_controller.dart';
import '../providers/voice_flags.dart';
import 'level_display_hold.dart';

class MutedTalkWatcher extends ConsumerStatefulWidget {
  const MutedTalkWatcher({
    super.key,
    required this.watching,
    required this.child,
  });

  /// True while muted by choice: not push-to-talk, not listen-only.
  final bool watching;
  final Widget child;

  @override
  ConsumerState<MutedTalkWatcher> createState() => _MutedTalkWatcherState();
}

class _MutedTalkWatcherState extends ConsumerState<MutedTalkWatcher> {
  final _tracker = MutedTalkTracker();
  late final ProviderContainer _container;

  @override
  void initState() {
    super.initState();
    _container = ProviderScope.containerOf(context, listen: false);
  }

  /// Deferred because the cue's listeners rebuild, and a provider must not change while the tree is being torn down.
  @override
  void dispose() {
    final container = _container;
    Future.microtask(() {
      try {
        if (container.read(mutedTalkCueProvider)) {
          container.read(mutedTalkCueProvider.notifier).state = false;
        }
      } on StateError {
        // The whole scope went first, taking the cue with it.
      }
    });
    super.dispose();
  }

  @override
  void didUpdateWidget(MutedTalkWatcher old) {
    super.didUpdateWidget(old);
    if (old.watching && !widget.watching) {
      _tracker.reset();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _show(ref, false);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // Where there is no native gate no reading ever arrives, so nothing fires.
    final gated = ref
        .read(voiceControllerProvider.notifier)
        .input
        .supportsInputGate;
    final active = widget.watching && gated;
    // A cue raised in one call must not greet the next one.
    ref.listen(voiceFlagsProvider.select((f) => f.state), (_, state) {
      if (state != VoiceSessionState.connected) _show(ref, false);
    });
    // Listening only while watching keeps the gate stream out of every unmuted call.
    if (active) {
      ref.listen(inputGateReadingProvider, (_, next) {
        final reading = next.valueOrNull;
        if (reading != null && _tracker.add(reading)) _show(ref, true);
      });
    }
    return LevelDisplayHold(active: active, child: widget.child);
  }
}

void _show(WidgetRef ref, bool shown) {
  if (ref.read(mutedTalkCueProvider) == shown) return;
  ref.read(mutedTalkCueProvider.notifier).state = shown;
  ref.read(dockHintEpochProvider.notifier).state++;
}
