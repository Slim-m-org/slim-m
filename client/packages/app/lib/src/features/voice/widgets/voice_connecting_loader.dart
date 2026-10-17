// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The moment between joining a voice channel and being in it, from the
/// "Voice Connecting" design: your avatar, a lane of dots, and the people
/// already in the room. The mark's accent square hops dot to dot between you
/// and them while the server is reached, lighting each dot it passes, then
/// settles at the room and a pulse runs back to you while audio is
/// negotiated. The status line names the real phase, never a scripted one.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:slimm_design_system/design_system.dart';

const int _dots = 7;
const double _pitch = 28;
const double _laneWidth = (_dots - 1) * _pitch;
const double _laneHeight = 40;
const double _square = 14;
const double _squareRadius = 4.5;

/// Seconds per hop, and before the first one.
const double _hop = 0.32;
const double _firstHopAt = 0.35;

/// How long the square takes to settle at the room once audio starts.
const double _settle = 0.35;

/// One pulse back along the lane, and the wait before the next.
const double _ackRun = 0.7;
const double _ackEvery = 1.6;

/// Where the loader is, from which side of the join it is waiting on.
enum VoiceConnectPhase { reaching, negotiating }

class VoiceConnectingLoader extends StatefulWidget {
  const VoiceConnectingLoader({
    super.key,
    required this.phase,
    required this.self,
    required this.room,
  });

  final VoiceConnectPhase phase;

  /// Your own avatar, at the start of the lane.
  final Widget self;

  /// The people already in the call, at its end.
  final Widget room;

  @override
  State<VoiceConnectingLoader> createState() => _VoiceConnectingLoaderState();
}

class _VoiceConnectingLoaderState extends State<VoiceConnectingLoader>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_onTick);
  double _seconds = 0;
  double? _negotiatingAt;

  /// Square position along the lane when negotiating began, in dots.
  double _settleFrom = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduced = AppMotion.isReduced(context);
    if (reduced && _ticker.isActive) _ticker.stop();
    if (!reduced && !_ticker.isActive) _ticker.start();
  }

  @override
  void didUpdateWidget(VoiceConnectingLoader oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.phase == VoiceConnectPhase.negotiating &&
        _negotiatingAt == null) {
      _settleFrom = _hopPosition(_seconds);
      _negotiatingAt = _seconds;
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  void _onTick(Duration elapsed) =>
      setState(() => _seconds = elapsed.inMicroseconds / 1e6);

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final reduced = AppMotion.isReduced(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        widget.self,
        const SizedBox(width: AppSpacing.s16),
        SizedBox(
          width: _laneWidth + _square,
          height: _laneHeight,
          child: CustomPaint(
            painter: _LanePainter(
              frame: reduced
                  ? const _LaneFrame.still()
                  : _frame(_seconds, _negotiatingAt, _settleFrom),
              dot: tokens.borderStrong,
              accent: tokens.accentFill,
            ),
          ),
        ),
        const SizedBox(width: AppSpacing.s16),
        widget.room,
      ],
    );
  }
}

double _cycle(double seconds) =>
    math.max(0.0, (seconds - _firstHopAt) / _hop) % (2 * (_dots - 1));

/// Where the square is, in dots from you, while the server is being reached:
/// out to the room and back, so a slow connection still reads as trying.
double _hopPosition(double seconds) {
  final cycle = _cycle(seconds);
  final leg = cycle.floor();
  final eased = leg + Curves.easeInOutCubic.transform(cycle - leg);
  return eased <= _dots - 1 ? eased : 2 * (_dots - 1) - eased;
}

_LaneFrame _frame(double t, double? negotiatingAt, double settleFrom) {
  final glow = List<double>.filled(_dots, 0);
  if (negotiatingAt == null) {
    final at = _hopPosition(t);
    final frac = _cycle(t) % 1;
    final heading = _cycle(t) < _dots - 1 ? 1 : -1;
    for (var i = 0; i < _dots; i++) {
      final behind = (at - i) * heading;
      if (behind >= -0.05) glow[i] = math.exp(-behind.abs() * 1.4);
    }
    return _LaneFrame(
      position: at,
      lift: -9 * math.sin(math.pi * frac),
      turns: at / 4,
      scale: 1,
      glow: glow,
    );
  }
  final since = t - negotiatingAt;
  final settle = Curves.easeInOutCubic.transform(
    (since / _settle).clamp(0.0, 1.0),
  );
  final position = settleFrom + (_dots - 1 - settleFrom) * settle;
  final pulse = ((since - _settle) % _ackEvery) / _ackRun;
  if (since > _settle && pulse < 1) {
    final front = (_dots - 1) * (1 - Curves.easeInOutCubic.transform(pulse));
    for (var i = 0; i < _dots; i++) {
      glow[i] = math.exp(-(front - i).abs() * 0.9);
    }
  }
  final breathing = since > _settle
      ? 1 + 0.08 * math.sin((since - _settle) * 7)
      : 1.0;
  return _LaneFrame(
    position: position,
    lift: 0,
    turns: settle < 1 ? position / 4 : 0,
    scale: breathing,
    glow: glow,
  );
}

class _LaneFrame {
  const _LaneFrame({
    required this.position,
    required this.lift,
    required this.turns,
    required this.scale,
    required this.glow,
  });

  const _LaneFrame.still()
    : position = 0,
      lift = 0,
      turns = 0,
      scale = 1,
      glow = const [0, 0, 0, 0, 0, 0, 0];

  final double position;
  final double lift;
  final double turns;
  final double scale;
  final List<double> glow;
}

class _LanePainter extends CustomPainter {
  const _LanePainter({
    required this.frame,
    required this.dot,
    required this.accent,
  });

  final _LaneFrame frame;
  final Color dot;
  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    final cy = size.height / 2;
    const left = _square / 2;
    final paint = Paint();
    for (var i = 0; i < _dots; i++) {
      final g = frame.glow[i];
      final lit = g > 0.08;
      paint.color = lit
          ? accent.withValues(alpha: 0.35 + 0.65 * g)
          : dot.withValues(alpha: 0.55);
      canvas.drawCircle(
        Offset(left + i * _pitch, cy),
        2.4 + (lit ? g : 0),
        paint,
      );
    }
    canvas
      ..save()
      ..translate(left + frame.position * _pitch, cy + frame.lift)
      ..rotate(frame.turns * 2 * math.pi)
      ..scale(frame.scale)
      ..drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(center: Offset.zero, width: _square, height: _square),
          const Radius.circular(_squareRadius),
        ),
        paint..color = accent,
      )
      ..restore();
  }

  @override
  bool shouldRepaint(_LanePainter oldDelegate) =>
      oldDelegate.frame != frame ||
      oldDelegate.dot != dot ||
      oldDelegate.accent != accent;
}
