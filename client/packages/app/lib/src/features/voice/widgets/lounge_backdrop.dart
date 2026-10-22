// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What sits behind the call stage: a soft glow of the channel's canvas when
/// it has anything on it, otherwise colour from the people in the call.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import '../../members/providers/user_profiles.dart';
import '../../members/widgets/profile_colour.dart';
import '../providers/lounge_canvas_glow.dart';

/// How many people's colours the aurora uses; more reads as noise.
const _auroraPeople = 4;

class LoungeBackdrop extends ConsumerWidget {
  const LoungeBackdrop({
    super.key,
    required this.channelId,
    required this.participants,
    this.canvas = true,
  });

  final String channelId;
  final List<VoiceParticipant> participants;

  /// False where the call has no canvas, such as a DM call.
  final bool canvas;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final glow = canvas
        ? ref.watch(loungeCanvasGlowProvider(channelId)).valueOrNull
        : null;
    final Widget body;
    if (glow != null) {
      body = Stack(
        fit: StackFit.expand,
        children: [
          RawImage(image: glow, fit: BoxFit.cover),
          ColoredBox(color: tokens.surfaceBase.withValues(alpha: 0.55)),
        ],
      );
    } else {
      body = CustomPaint(
        painter: _AuroraPainter(
          pools: [
            for (final p in participants.take(_auroraPeople))
              if (_colourOf(ref, p.identity) case final colour?)
                (colour, p.isSpeaking),
          ],
          dark: Theme.of(context).brightness == Brightness.dark,
        ),
      );
    }
    return IgnorePointer(
      child: ExcludeSemantics(child: RepaintBoundary(child: body)),
    );
  }

  static Color? _colourOf(WidgetRef ref, String identity) {
    final profile = ref.watch(userProfileProvider(identity)).valueOrNull;
    return profile == null
        ? null
        : profileColourOf(
            index: profile.profileColor,
            rgb: profile.profileColorRgb,
          );
  }
}

/// Soft pools of each person's colour; already-soft gradients, so nothing is blurred per frame.
class _AuroraPainter extends CustomPainter {
  _AuroraPainter({required this.pools, required this.dark});

  final List<(Color, bool)> pools;
  final bool dark;

  static const _spots = [
    Offset(.22, .3),
    Offset(.78, .28),
    Offset(.5, .82),
    Offset(.15, .8),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    for (var i = 0; i < pools.length; i++) {
      final (colour, speaking) = pools[i];
      final spot = _spots[i % _spots.length];
      final centre = Offset(spot.dx * size.width, spot.dy * size.height);
      final radius = size.shortestSide * (speaking ? 0.7 : 0.55);
      final strength = math.min(
        (dark ? 0.26 : 0.2) * (speaking ? 1.4 : 1),
        0.4,
      );
      canvas.drawCircle(
        centre,
        radius,
        Paint()
          ..shader = RadialGradient(
            colors: [
              colour.withValues(alpha: strength),
              colour.withValues(alpha: 0),
            ],
          ).createShader(Rect.fromCircle(center: centre, radius: radius)),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _AuroraPainter oldDelegate) =>
      oldDelegate.dark != dark || !_samePools(oldDelegate.pools, pools);

  static bool _samePools(List<(Color, bool)> a, List<(Color, bool)> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
