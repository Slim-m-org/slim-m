// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Participants arriving in and leaving a call as motion, not teleports.
///
/// [AnimatedRosterWrap] carries the same exiting-registry shape
/// `ReactionsRow` uses for its chips: a participant who leaves keeps their
/// tile mounted for one short exit animation (inert behind [IgnorePointer])
/// before the wrap reflows, and one who joins pops in at their final
/// position rather than appearing at full size. Tile order is preserved
/// across roster updates, so an unrelated join or leave never shuffles the
/// tiles somebody is looking at. Under reduce motion a leaver vanishes at
/// once and a joiner lands settled, both via [AppMotion.reduced].
library;

import 'package:flutter/widgets.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

class AnimatedRosterWrap extends StatefulWidget {
  const AnimatedRosterWrap({
    required this.participants,
    required this.tileFor,
    this.spacing = 0,
    this.runSpacing = 0,
    super.key,
  });

  final List<VoiceParticipant> participants;

  /// Builds one participant's tile; a leaver's exit reuses it with a stilled
  /// copy of their last roster entry (no camera, not speaking), since neither
  /// can be live for somebody already gone.
  final Widget Function(BuildContext context, VoiceParticipant participant)
  tileFor;

  final double spacing;
  final double runSpacing;

  @override
  State<AnimatedRosterWrap> createState() => _AnimatedRosterWrapState();
}

class _AnimatedRosterWrapState extends State<AnimatedRosterWrap> {
  final Map<String, VoiceParticipant> _exiting = {};
  late List<String> _order = [for (final p in widget.participants) p.identity];

  @override
  void didUpdateWidget(AnimatedRosterWrap oldWidget) {
    super.didUpdateWidget(oldWidget);
    final live = {for (final p in widget.participants) p.identity};
    if (!AppMotion.isReduced(context)) {
      for (final p in oldWidget.participants) {
        if (!live.contains(p.identity)) _exiting[p.identity] = _stilled(p);
      }
    }
    _exiting.removeWhere((identity, _) => live.contains(identity));
    final kept = [
      for (final identity in _order)
        if (live.contains(identity) || _exiting.containsKey(identity)) identity,
    ];
    final known = kept.toSet();
    for (final p in widget.participants) {
      if (!known.contains(p.identity)) kept.add(p.identity);
    }
    _order = kept;
  }

  static VoiceParticipant _stilled(VoiceParticipant p) => VoiceParticipant(
    identity: p.identity,
    name: p.name,
    isSpeaking: false,
    isMuted: p.isMuted,
    isLocal: p.isLocal,
    isScreenSharing: false,
  );

  @override
  Widget build(BuildContext context) {
    final live = {for (final p in widget.participants) p.identity: p};
    return Wrap(
      alignment: WrapAlignment.center,
      spacing: widget.spacing,
      runSpacing: widget.runSpacing,
      children: [
        for (final identity in _order)
          if (live[identity] case final participant?)
            CallTilePop(
              key: ValueKey('tile-$identity'),
              child: widget.tileFor(context, participant),
            )
          else if (_exiting[identity] case final participant?)
            CallTileExit(
              key: ValueKey('tile-exit-$identity'),
              onDone: () => setState(() => _exiting.remove(identity)),
              child: widget.tileFor(context, participant),
            ),
      ],
    );
  }
}

/// One tile popping in: a fade plus a small scale-up, once, on mount.
class CallTilePop extends StatelessWidget {
  const CallTilePop({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween(begin: 0, end: 1),
    duration: AppMotion.reduced(context, AppMotion.base),
    curve: AppMotion.entrance,
    builder: (context, t, child) => Opacity(
      opacity: t,
      child: Transform.scale(scale: 0.92 + 0.08 * t, child: child),
    ),
    child: child,
  );
}

/// One tile playing out after its participant left: inert, fading and
/// shrinking over [AppMotion.pop], then released through [onDone] so the
/// wrap reflows once the motion has said goodbye rather than the frame the
/// roster did.
class CallTileExit extends StatelessWidget {
  const CallTileExit({required this.onDone, required this.child, super.key});

  final VoidCallback onDone;
  final Widget child;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween(begin: 1, end: 0),
    duration: AppMotion.reduced(context, AppMotion.pop),
    curve: AppMotion.exit,
    onEnd: onDone,
    builder: (context, t, child) => Opacity(
      opacity: t,
      child: Transform.scale(scale: 0.92 + 0.08 * t, child: child),
    ),
    child: IgnorePointer(child: child),
  );
}
