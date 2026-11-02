// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The horizontal strip of small tiles under a call's stage, and the cues that
/// say when it holds more than fits.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import 'call_participant_tiles.dart';
import 'call_roster_motion.dart';

const double _gap = AppSpacing.s12;

/// How many speakers sit wholly outside a strip's view on each side.
typedef HiddenSpeakers = ({int before, int after});

/// The speakers in [speaking] that the strip scrolled to [offset] and
/// [viewport] wide does not show at all. A tile that is partly in view still
/// shows its ring, so only a wholly hidden one counts.
HiddenSpeakers hiddenSpeakers({
  required double offset,
  required double viewport,
  required List<double> widths,
  required List<bool> speaking,
}) {
  var before = 0;
  var after = 0;
  var start = 0.0;
  for (var i = 0; i < widths.length; i++) {
    final end = start + widths[i];
    if (speaking[i]) {
      if (end <= offset) before++;
      if (start >= offset + viewport) after++;
    }
    start = end + _gap;
  }
  return (before: before, after: after);
}

/// Whether tiles [widths] wide, with the gaps between them, overflow [viewport].
bool stripOverflows(List<double> widths, double viewport) =>
    widths.isNotEmpty &&
    widths.fold<double>(0, (sum, w) => sum + w) + (widths.length - 1) * _gap >
        viewport + 0.5;

/// Enter-only motion: a joiner's tile pops in, while a leaver here reflows
/// at once, since a separated horizontal strip has no in-place slot for an
/// exit the way [AnimatedRosterWrap]'s grid does.
///
/// It never scrolls itself to a speaker (the stage is not a speaker view).
/// A bar that stays visible while it overflows, drag with a mouse, a plain
/// wheel, and a chip for speakers out of view are how people find them.
class CallFilmstrip extends StatefulWidget {
  const CallFilmstrip({
    super.key,
    required this.leading,
    required this.leadingItemWidth,
    required this.participants,
    required this.tileBuilder,
  });

  /// Share thumbnails shown ahead of the participant tiles, each [leadingItemWidth] wide.
  final List<Widget> leading;
  final double leadingItemWidth;
  final List<VoiceParticipant> participants;
  final Widget Function(BuildContext context, VoiceParticipant participant)
  tileBuilder;

  @override
  State<CallFilmstrip> createState() => _CallFilmstripState();
}

class _CallFilmstripState extends State<CallFilmstrip> {
  final _controller = ScrollController();

  List<double> get _widths => [
    for (final _ in widget.leading) widget.leadingItemWidth,
    for (final _ in widget.participants) kCallTileMinWidth,
  ];

  List<bool> get _speaking => [
    for (final _ in widget.leading) false,
    for (final p in widget.participants) p.isSpeaking,
  ];

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  // A plain wheel carries only a vertical delta, which a horizontal list ignores.
  void _onWheel(PointerSignalEvent event) {
    if (event is! PointerScrollEvent || !_controller.hasClients) return;
    final delta = event.scrollDelta;
    if (delta.dx != 0 || delta.dy == 0) return;
    final position = _controller.position;
    final target = (position.pixels + delta.dy).clamp(
      0.0,
      position.maxScrollExtent,
    );
    if (target == position.pixels) return;
    GestureBinding.instance.pointerSignalResolver.register(
      event,
      (_) => _controller.jumpTo(target),
    );
  }

  void _reveal(bool before, double viewport) {
    final widths = _widths;
    final speaking = _speaking;
    final offset = _controller.hasClients ? _controller.offset : 0.0;
    var start = 0.0;
    double? target;
    for (var i = 0; i < widths.length; i++) {
      final end = start + widths[i];
      if (speaking[i]) {
        if (before && end <= offset) target = start;
        if (!before && start >= offset + viewport) {
          target = end - viewport;
          break;
        }
      }
      start = end + _gap;
    }
    if (target == null || !_controller.hasClients) return;
    _controller.animateTo(
      target.clamp(0.0, _controller.position.maxScrollExtent),
      duration: AppMotion.reducedSize(context, AppMotion.base),
      curve: AppMotion.entrance,
    );
  }

  @override
  Widget build(BuildContext context) {
    final widths = _widths;
    final behavior = ScrollConfiguration.of(context).copyWith(
      scrollbars: false,
      dragDevices: const {
        PointerDeviceKind.touch,
        PointerDeviceKind.mouse,
        PointerDeviceKind.trackpad,
        PointerDeviceKind.stylus,
      },
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewport = constraints.maxWidth;
        final overflows = stripOverflows(widths, viewport);
        return Listener(
          onPointerSignal: _onWheel,
          child: ListenableBuilder(
            listenable: _controller,
            builder: (context, _) {
              final hidden = overflows
                  ? hiddenSpeakers(
                      offset: _controller.hasClients ? _controller.offset : 0,
                      viewport: viewport,
                      widths: widths,
                      speaking: _speaking,
                    )
                  : (before: 0, after: 0);
              return Stack(
                children: [
                  ScrollConfiguration(
                    behavior: behavior,
                    child: Scrollbar(
                      key: filmstripScrollbarKey,
                      controller: _controller,
                      thumbVisibility: overflows,
                      child: Center(child: _strip()),
                    ),
                  ),
                  if (hidden.before > 0)
                    _chipAt(Alignment.centerLeft, hidden.before, () {
                      _reveal(true, viewport);
                    }),
                  if (hidden.after > 0)
                    _chipAt(Alignment.centerRight, hidden.after, () {
                      _reveal(false, viewport);
                    }),
                ],
              );
            },
          ),
        );
      },
    );
  }

  Widget _chipAt(Alignment side, int count, VoidCallback onTap) =>
      Positioned.fill(
        child: Align(
          alignment: side,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s4),
            child: MoreSpeakingChip(
              key: moreSpeakingChipKey,
              count: count,
              onTap: onTap,
            ),
          ),
        ),
      );

  /// Stored with the page, so the offset survives the stage being swapped for the canvas.
  Widget _strip() => ListView.separated(
    key: const PageStorageKey<String>('call-filmstrip-scroll'),
    controller: _controller,
    scrollDirection: Axis.horizontal,
    shrinkWrap: true,
    itemCount: widget.leading.length + widget.participants.length,
    separatorBuilder: (context, index) => const SizedBox(width: _gap),
    itemBuilder: (context, index) {
      if (index < widget.leading.length) {
        return Center(child: widget.leading[index]);
      }
      final participant = widget.participants[index - widget.leading.length];
      return Center(
        // Keyed at the item root so a roster shift never replays the pop.
        key: ValueKey('film-${participant.identity}'),
        child: CallTilePop(child: widget.tileBuilder(context, participant)),
      );
    },
  );
}

/// The bar a strip keeps while it overflows, for tests to find.
const filmstripScrollbarKey = ValueKey('filmstrip-scrollbar');

/// The chip naming hidden speakers, for tests to find.
const moreSpeakingChipKey = ValueKey('filmstrip-more-speaking');

/// The ringed chip at a strip's edge naming speakers scrolled out of view.
class MoreSpeakingChip extends StatelessWidget {
  const MoreSpeakingChip({super.key, required this.count, required this.onTap});

  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Semantics(
      button: true,
      label: '$count more speaking, out of view',
      excludeSemantics: true,
      onTap: onTap,
      child: AppTouchHitArea(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.s8,
              vertical: AppSpacing.s4,
            ),
            decoration: BoxDecoration(
              color: tokens.surfaceRaised,
              borderRadius: BorderRadius.circular(AppRadii.full),
              border: Border.all(color: tokens.accent, width: 2),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              spacing: AppSpacing.s4,
              children: [
                Icon(AppIcons.speaker, size: 12, color: tokens.accent),
                Text(
                  '$count more',
                  style: AppText.caption.copyWith(color: tokens.textPrimary),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
