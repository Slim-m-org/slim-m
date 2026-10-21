// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Feeds who is talking on the call into the canvas cursors, so a speaker's
/// cursor label glows (decision 0086). It lives beside the pane rather than in
/// it so a speaking flip repaints one painter instead of rebuilding the pane.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import '../../voice/providers/voice_flags.dart';

final _speakingIdsProvider = Provider<Set<String>>((ref) {
  final participants = ref.watch(voiceParticipantsProvider);
  return {
    for (final p in participants)
      if (p.isSpeaking && !p.isLocal) p.identity,
  };
});

class CanvasSpeakingSync extends ConsumerStatefulWidget {
  const CanvasSpeakingSync({super.key, required this.cursors});

  final CanvasCursors? cursors;

  @override
  ConsumerState<CanvasSpeakingSync> createState() => _CanvasSpeakingSyncState();
}

class _CanvasSpeakingSyncState extends ConsumerState<CanvasSpeakingSync> {
  @override
  void initState() {
    super.initState();
    widget.cursors?.setSpeaking(ref.read(_speakingIdsProvider));
    ref.listenManual<Set<String>>(
      _speakingIdsProvider,
      (_, ids) => widget.cursors?.setSpeaking(ids),
    );
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
