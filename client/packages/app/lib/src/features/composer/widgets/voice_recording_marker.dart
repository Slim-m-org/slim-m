// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A voice message still recording while its composer is off screen: a red
/// dot, its channel and its clock, one tap back to that composer. The rail's
/// footer carries it as a row, and a phone's chat as a bottom strip.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../routing/breakpoints.dart';
import '../../../routing/routes.dart';
import '../../../widgets/voice_waveform.dart' show formatVoiceDuration;
import '../../channels/providers/channel_by_id_provider.dart';
import '../../channels/providers/threads.dart';
import '../../channels/widgets/channel_label.dart';
import '../../voice/widgets/call_strip_press_area.dart';
import '../providers/voice_recording.dart';

/// The marker's root in either place.
const voiceRecordingMarkerKey = Key('voice_recording_marker');

/// The channel recording a voice message whose composer neither
/// [activeChannelId] nor a docked thread shows.
String? recordingElsewhere(
  BuildContext context,
  WidgetRef ref,
  String? activeChannelId,
) {
  final id = ref.watch(recordingVoiceChannelProvider);
  if (id == null || id == activeChannelId) return null;
  final width = MediaQuery.sizeOf(context).width;
  final docked =
      ref.watch(openThreadProvider) == id &&
      LayoutClass.fromWidth(width).fitsThreadPane(width);
  return docked ? null : id;
}

/// The rail footer's row, in the call row's columns: the dot over the avatar.
class VoiceRecordingRow extends ConsumerStatefulWidget {
  const VoiceRecordingRow({super.key, required this.channelId});

  final String channelId;

  @override
  ConsumerState<VoiceRecordingRow> createState() => _VoiceRecordingRowState();
}

class _VoiceRecordingRowState extends ConsumerState<VoiceRecordingRow> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final channel = ref
        .watch(channelByIdProvider(widget.channelId))
        .valueOrNull;
    final where = _where(channel);
    return Tooltip(
      message: where == null ? 'Go to the voice message' : 'Go to $where',
      excludeFromSemantics: true,
      child: Semantics(
        key: voiceRecordingMarkerKey,
        button: true,
        label: _backLabel(where),
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (_) => setState(() => _pressed = true),
            onTapUp: (_) => setState(() => _pressed = false),
            onTapCancel: () => setState(() => _pressed = false),
            onTap: () {
              AppHaptics.selection();
              _goBack(context, widget.channelId, channel);
            },
            child: AnimatedOpacity(
              opacity: _pressed ? 0.6 : 1,
              duration: AppMotion.reduced(context, AppMotion.fast),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minHeight: AppTouchTargets.of(context)
                      ? AppSizes.rowTouch
                      : AppSizes.rowPointer,
                ),
                child: Row(
                  children: [
                    const SizedBox(
                      width: AppSizes.rowTouch,
                      child: Center(child: _Dot()),
                    ),
                    // The user bar's own gap, so the text starts under its name.
                    const SizedBox(width: 9),
                    Expanded(
                      child: _Line(channelId: widget.channelId, where: where),
                    ),
                    // The rail's content edge, where the search box and unread dots end.
                    const SizedBox(width: AppSpacing.s8),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// How far inside its touch target the call strip's Leave draws its box, so
/// the strip's clock ends where that box does.
const double _leaveBoxInset = (AppSizes.rowTouch - AppSizes.icon28) / 2;

/// A phone's bottom strip, the call strip's twin, which it sits over.
class VoiceRecordingStrip extends ConsumerWidget {
  const VoiceRecordingStrip({super.key, required this.activeChannelId});

  final String? activeChannelId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = recordingElsewhere(context, ref, activeChannelId);
    if (id == null) return const SizedBox.shrink();
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final channel = ref.watch(channelByIdProvider(id)).valueOrNull;
    final where = _where(channel);
    return Container(
      key: voiceRecordingMarkerKey,
      constraints: const BoxConstraints(minHeight: AppSizes.rowTouch),
      decoration: BoxDecoration(
        color: tokens.surfaceSunken,
        border: Border(top: BorderSide(color: tokens.borderSubtle)),
      ),
      child: Stack(
        alignment: AlignmentDirectional.centerStart,
        children: [
          Positioned.fill(
            child: CallStripPressArea(
              semanticLabel: _backLabel(where),
              onPressed: () => _goBack(context, id, channel),
            ),
          ),
          IgnorePointer(
            child: Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(
                AppSpacing.s12,
                AppSpacing.s8,
                AppSpacing.s12 + _leaveBoxInset,
                AppSpacing.s8,
              ),
              child: Row(
                children: [
                  const _Dot(),
                  const SizedBox(width: AppSpacing.s8),
                  Expanded(
                    child: _Line(channelId: id, where: where),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// `#general`, a person for a DM, or null for a thread or a channel not held.
String? _where(Channel? channel) {
  if (channel == null || channel.name.isEmpty) return null;
  return channelDisplayLabel(channel);
}

String _backLabel(String? where) => where == null
    ? 'Back to the voice message'
    : 'Back to the voice message in $where';

/// Back to its composer; a thread docks again where the pane fits.
void _goBack(BuildContext context, String channelId, Channel? channel) {
  final width = MediaQuery.sizeOf(context).width;
  if (channel?.parentMessageId != null &&
      LayoutClass.fromWidth(width).fitsThreadPane(width)) {
    dockThread(ProviderScope.containerOf(context, listen: false), channelId);
  } else {
    context.go(Routes.channel(channelId));
  }
}

/// The composer's own recording dot.
class _Dot extends StatelessWidget {
  const _Dot();

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(
        color: tokens.dangerText,
        shape: BoxShape.circle,
      ),
    );
  }
}

/// Where it records, then its clock; only the clock rebuilds each second. A
/// rail too narrow for "Recording in" keeps the channel, which the dot explains.
class _Line extends ConsumerWidget {
  const _Line({required this.channelId, required this.where});

  final String channelId;
  final String? where;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final secondary = AppText.caption.copyWith(color: tokens.textSecondary);
    final where = this.where;
    final place = where == null
        ? null
        : TextSpan(
            text: where,
            style: TextStyle(
              color: tokens.textPrimary,
              fontWeight: AppWeights.medium,
            ),
          );
    final full = TextSpan(
      text: place == null ? 'Recording a voice message' : 'Recording in ',
      children: [?place],
    );
    return ExcludeSemantics(
      child: Row(
        children: [
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) => Text.rich(
                place == null ||
                        _fitsOneLine(context, full, secondary, constraints)
                    ? full
                    : place,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: secondary,
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.s8),
          _Clock(channelId: channelId, style: secondary),
        ],
      ),
    );
  }
}

bool _fitsOneLine(
  BuildContext context,
  InlineSpan span,
  TextStyle style,
  BoxConstraints constraints,
) {
  final painter = TextPainter(
    text: TextSpan(
      style: DefaultTextStyle.of(context).style.merge(style),
      children: [span],
    ),
    maxLines: 1,
    textDirection: Directionality.of(context),
    textScaler: MediaQuery.textScalerOf(context),
  )..layout(maxWidth: constraints.maxWidth);
  final fits = !painter.didExceedMaxLines;
  painter.dispose();
  return fits;
}

class _Clock extends ConsumerWidget {
  const _Clock({required this.channelId, required this.style});

  final String channelId;
  final TextStyle style;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final seconds = ref.watch(
      voiceRecorderProvider(channelId).select((s) => s.elapsed.inSeconds),
    );
    return Text(
      formatVoiceDuration(Duration(seconds: seconds)),
      style: style.copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
    );
  }
}
