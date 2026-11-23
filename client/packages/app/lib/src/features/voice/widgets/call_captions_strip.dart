// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Captions: the call's newest transcript lines under the stage, while the
/// server transcribes the call and this member may read it (decision 0113).
///
/// The strip keeps one height while captions are on, so the stage (decision
/// 0114) resizes once when they are turned on and never per line.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../members/providers/user_profiles.dart';
import '../providers/call_transcript.dart';
import '../providers/live_call_transcript.dart';
import '../providers/voice_settings_controller.dart';

/// Lines the strip has room for on a tall window.
const captionLines = 3;

/// Below this window height the strip keeps two lines, so the stage keeps its room.
const double _shortWindow = 500;

/// How many text lines the strip shows in this window.
int captionLinesFor(BuildContext context) =>
    MediaQuery.sizeOf(context).height < _shortWindow ? 2 : captionLines;

/// How long the strip keeps its lines once nobody has said anything new.
const captionHold = Duration(seconds: 8);

const callCaptionsKey = Key('call-captions');

/// Whether [channelId]'s call shows captions for this member right now.
bool captionsShown(WidgetRef ref, String channelId) =>
    ref.watch(liveCallTranscriptIdProvider(channelId)) != null &&
    ref.watch(voiceSettingsControllerProvider.select((s) => s.showCaptions));

/// The strip's fixed height at this text scale.
double captionsHeight(BuildContext context) {
  final line = MediaQuery.textScalerOf(context).scale(AppText.body.fontSize!);
  return line * AppText.body.height! * captionLinesFor(context) +
      AppSpacing.s8 * 2;
}

class CallCaptionsStrip extends ConsumerWidget {
  const CallCaptionsStrip({
    super.key,
    required this.channelId,
    this.gap = const EdgeInsets.only(top: AppSpacing.s8),
  });

  final String channelId;

  /// Space kept from what sits beside the strip, only while it shows.
  final EdgeInsets gap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final transcriptId = ref.watch(liveCallTranscriptIdProvider(channelId));
    if (transcriptId == null || !captionsShown(ref, channelId)) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: gap,
      child: _Captions(key: ValueKey(transcriptId), transcriptId: transcriptId),
    );
  }
}

class _Captions extends ConsumerStatefulWidget {
  const _Captions({super.key, required this.transcriptId});

  final String transcriptId;

  @override
  ConsumerState<_Captions> createState() => _CaptionsState();
}

class _CaptionsState extends ConsumerState<_Captions> {
  /// The last line that was already said when the strip opened, or shown since.
  int? _seen;
  final _shown = <api.TranscriptLine>[];
  Timer? _clear;

  @override
  void initState() {
    super.initState();
    final model = ref.read(callTranscriptProvider(widget.transcriptId));
    if (model.loaded) _seen = model.lines.isEmpty ? 0 : model.lines.last.seq;
  }

  @override
  void dispose() {
    _clear?.cancel();
    super.dispose();
  }

  void _onModel(CallTranscriptModel next) {
    if (!next.loaded) return;
    final seen = _seen;
    if (seen == null) {
      // What was said before the strip opened is the pane's to show, not a caption.
      _seen = next.lines.isEmpty ? 0 : next.lines.last.seq;
      return;
    }
    final fresh = [
      for (final line in next.lines)
        if (line.seq > seen) line,
    ];
    if (fresh.isEmpty) return;
    _seen = fresh.last.seq;
    setState(() {
      _shown.addAll(fresh);
      if (_shown.length > captionLines) {
        _shown.removeRange(0, _shown.length - captionLines);
      }
    });
    _clear?.cancel();
    _clear = Timer(captionHold, () {
      if (mounted) setState(_shown.clear);
    });
    fresh.forEach(_announce);
  }

  String _name(String userId) =>
      ref.read(userProfileProvider(userId)).valueOrNull?.displayName ??
      'Someone';

  void _announce(api.TranscriptLine line) {
    if (!MediaQuery.supportsAnnounceOf(context)) return;
    final view = View.maybeOf(context);
    if (view == null) return;
    final direction = Directionality.maybeOf(context) ?? TextDirection.ltr;
    final text = '${_name(line.speakerId)}: ${line.text}';
    unawaited(SemanticsService.sendAnnouncement(view, text, direction));
  }

  TextSpan _span(api.TranscriptLine line) => TextSpan(
    children: [
      TextSpan(
        text: '${_name(line.speakerId)}: ',
        style: const TextStyle(fontWeight: AppWeights.medium),
      ),
      TextSpan(text: line.text),
    ],
  );

  /// The newest lines that fit whole, each with its speaker, so nothing starts mid-sentence.
  List<Widget> _wholeEntries(
    BuildContext context,
    double width,
    AppTokens tokens,
  ) {
    final style = AppText.body.copyWith(color: tokens.textPrimary);
    final scaler = MediaQuery.textScalerOf(context);
    final room = captionLinesFor(context);
    var used = 0;
    final shown = <Widget>[];
    for (final line in _shown.reversed) {
      final painter = TextPainter(
        text: TextSpan(style: style, children: [_span(line)]),
        textDirection: Directionality.of(context),
        textScaler: scaler,
      )..layout(maxWidth: width);
      final lines = painter.computeLineMetrics().length;
      painter.dispose();
      if (used + lines > room && shown.isNotEmpty) break;
      used += lines;
      shown.insert(
        0,
        Text.rich(
          _span(line),
          key: ValueKey('caption-${line.seq}'),
          maxLines: room,
          overflow: TextOverflow.ellipsis,
          style: style,
        ),
      );
      if (used >= room) break;
    }
    return shown;
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(
      callTranscriptProvider(widget.transcriptId),
      (_, next) => _onModel(next),
    );
    final tokens = Theme.of(context).extension<AppTokens>()!;
    for (final line in _shown) {
      ref.watch(userProfileProvider(line.speakerId));
    }
    return ExcludeSemantics(
      child: Container(
        key: callCaptionsKey,
        height: captionsHeight(context),
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.s12,
          vertical: AppSpacing.s8,
        ),
        decoration: BoxDecoration(
          color: tokens.surfaceSunken,
          borderRadius: BorderRadius.circular(AppRadii.card),
        ),
        child: SizedBox(
          width: double.infinity,
          child: LayoutBuilder(
            builder: (context, box) => ClipRect(
              child: OverflowBox(
                maxHeight: double.infinity,
                alignment: Alignment.bottomLeft,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: _wholeEntries(context, box.maxWidth, tokens),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
