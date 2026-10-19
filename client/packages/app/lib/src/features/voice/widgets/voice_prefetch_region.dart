// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Warms a voice channel's join token while a pointer rests on its row, focus
/// reaches it, or a finger lands, so the click that follows skips the round trip.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_rtc/rtc.dart';

import '../providers/voice_flags.dart';
import '../providers/voice_token_prefetch.dart';

/// How long a pointer must rest before it counts as intent; a sweep across the
/// rail should not mint a token for every row it crosses.
const kVoicePrefetchDwell = Duration(milliseconds: 150);

class VoicePrefetchRegion extends ConsumerStatefulWidget {
  const VoicePrefetchRegion({
    required this.channelId,
    required this.child,
    super.key,
  });

  final String channelId;
  final Widget child;

  @override
  ConsumerState<VoicePrefetchRegion> createState() =>
      _VoicePrefetchRegionState();
}

class _VoicePrefetchRegionState extends ConsumerState<VoicePrefetchRegion> {
  Timer? _dwell;

  void _prefetch() {
    _dwell?.cancel();
    final voice = ref.read(voiceFlagsProvider);
    final inThisCall =
        voice.channelId == widget.channelId &&
        (voice.state == VoiceSessionState.connected ||
            voice.state == VoiceSessionState.connecting);
    if (inThisCall) return;
    ref.read(voiceTokenPrefetchProvider).prefetch(widget.channelId);
  }

  void _hoverStarted() {
    _dwell?.cancel();
    _dwell = Timer(kVoicePrefetchDwell, _prefetch);
  }

  @override
  void dispose() {
    _dwell?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (_) => _prefetch(),
      child: MouseRegion(
        onEnter: (_) => _hoverStarted(),
        onExit: (_) => _dwell?.cancel(),
        child: Focus(
          canRequestFocus: false,
          skipTraversal: true,
          includeSemantics: false,
          onFocusChange: (focused) {
            if (focused) _prefetch();
          },
          child: widget.child,
        ),
      ),
    );
  }
}
