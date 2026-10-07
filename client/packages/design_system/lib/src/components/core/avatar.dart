// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The user picture: round for a person, square for a non-human author (a
/// webhook, a CI bot).
///
/// A round avatar gets a generated tint from a closed six-colour list and
/// mono initials; a square one gets none of that; the shape difference is
/// what marks a non-human author, since it survives a screenshot the way a
/// colour convention alone would not.
library;

import 'package:flutter/material.dart';

import '../../app_metrics.dart';
import '../../app_tokens.dart';
import '../../app_typography.dart';
import '../../stable_index.dart';
import 'avatar_geometry.dart';
import 'presence_phone_mark.dart';
import 'speaking_ring.dart';
import 'status_dot.dart';

/// [circle] is the default, for a person. [square] marks a non-human
/// author.
enum AppAvatarShape { circle, square }

/// The closed six-colour set a round avatar's tint is hashed from; kept local
/// because token values are gated behind a design review.
const List<Color> _avatarTints = [
  Color(0xFF4E6B66),
  Color(0xFF5C6E7A),
  Color(0xFF6A5B6E),
  Color(0xFF59685C),
  Color(0xFF6A6152),
  Color(0xFF4F5B66),
];

Color _tintFor(String source) =>
    _avatarTints[stableIndexFor(source, _avatarTints.length)];

/// Alphanumeric characters only, first two, uppercased. Not "first letter of
/// first and last word": a punctuation-stripped prefix is what the source
/// design actually does, and porting a friendlier-looking guess instead would
/// mean the same person's initials differ between this port and the rest of
/// the product.
///
/// Public because it is the one initials rule: `onboarding_shell.dart` used
/// to carry its own copy without the symbol-stripping, so the same name
/// rendered different initials in the server chip than everywhere else (the
/// 2026-08-11 review's second-initials finding).
String initialsFor(String name) {
  final stripped = name.replaceAll(RegExp('[^a-zA-Z0-9]'), '');
  final take = stripped.length < 2 ? stripped.length : 2;
  return stripped.substring(0, take).toUpperCase();
}

/// Light ink for the fixed tints above; every themed text colour inverts and
/// would go illegible on them in dark.
const Color _avatarTintInk = Color(0xFFFFFFFF);

/// A person's (or bot's) picture, falling back to a tinted initials disc (or,
/// for a square avatar, to [placeholder]) when [image] is null or fails to
/// load.
///
/// The picture draws at [FilterQuality.medium]: an avatar is nearly always
/// minified at paint time (decoded at 3x, painted at 1x), the regime medium's
/// mipmap exists for, and [FilterQuality.low] made avatars read as soft.
class AppAvatar extends StatelessWidget {
  const AppAvatar({
    super.key,
    required this.name,
    this.tintKey,
    this.image,
    this.size = AppAvatarSize.s36,
    this.shape = AppAvatarShape.circle,
    this.status,
    this.mobileOnly = false,
    this.speaking = false,
    this.ringColor,
    this.placeholder,
    this.semanticLabel,
  });

  /// The display name a round avatar's initials are derived from, the
  /// fallback accessible label, and - only when [tintKey] is null - the
  /// tint hash source.
  final String name;

  /// The stable identity the tint is hashed from: a user id, wherever the
  /// caller knows one. Tint is an identity cue, and hashing it from the
  /// display string gave the same person two colours on one screen (the
  /// member list's "Ada Lovelace" beside the call recap's "Ada") and
  /// recoloured anyone who edited their name. Null falls back to [name],
  /// for content with no author identity - a channel, a system row.
  final String? tintKey;
  final ImageProvider? image;

  /// Diameter: one of the [AppAvatarSize] steps.
  final double size;
  final AppAvatarShape shape;

  /// Presence overlay, drawn bottom-right. Composes [AppStatusDot] rather
  /// than duplicating its shape-per-state drawing. Null and
  /// [AppPresence.unknown] both draw nothing.
  final AppPresence? status;

  /// The member is online from a phone and nothing else: an online [status]
  /// then draws a phone glyph in place of its dot. Away and do-not-disturb
  /// keep their dot, whose shape is what tells those states apart.
  final bool mobileOnly;

  /// A live-speaking ring. Takes priority over [ringColor], matching the
  /// source design's own precedence.
  ///
  /// It also reaches the accessible name, as `<name>, speaking`. The ring was
  /// the only thing carrying that, so who is talking in a call was information
  /// a sighted viewer got and a screen reader user did not. A caller that
  /// passes its own [semanticLabel] owns the whole name and gets no suffix -
  /// which is the way out for a surface borrowing this ring to mean something
  /// other than speech.
  final bool speaking;

  /// A caller-supplied ring (a fingerprint-confirmation colour strip, for
  /// instance), drawn when [speaking] is false.
  final Color? ringColor;

  /// Content for a [AppAvatarShape.square] avatar with no [image]: a square
  /// avatar never shows generated initials, since a bot's identity is its
  /// icon, not a name hash.
  final Widget? placeholder;

  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final round = shape == AppAvatarShape.circle;
    final radius = round ? size / 2 : AppRadii.control;
    final initials = round ? initialsFor(name) : '';
    final presence = status;
    final dot = presence != null && presence != AppPresence.unknown;
    final phone = dot && mobileOnly && presence == AppPresence.online;
    final geometry = AppAvatarGeometry(size, phone: phone);

    Widget content = image == null
        ? _Face(
            round: round,
            initials: initials,
            tokens: tokens,
            geometry: geometry,
            withDot: dot,
            tintSource: tintKey ?? name,
            placeholder: placeholder)
        : Image(
            image: image!,
            width: size,
            height: size,
            fit: BoxFit.cover,
            filterQuality: FilterQuality.medium,
            errorBuilder: (context, error, stack) => _Face(
              round: round,
              initials: initials,
              tokens: tokens,
              geometry: geometry,
              withDot: dot,
              tintSource: tintKey ?? name,
              placeholder: placeholder,
            ),
          );

    content = SizedBox(
      width: size,
      height: size,
      child: ClipRRect(
          borderRadius: BorderRadius.circular(radius), child: content),
    );

    // A foreground overlay, not a bordered wrapper, so layout size never moves.
    if (speaking) {
      content = AppSpeakingRing(
        color: tokens.accentFill,
        size: size,
        round: round,
        radius: radius,
        glyphBackgroundColor: tokens.surfaceBase,
        child: content,
      );
    } else if (ringColor != null) {
      content = Container(
        foregroundDecoration: BoxDecoration(
          shape: round ? BoxShape.circle : BoxShape.rectangle,
          borderRadius: round ? null : BorderRadius.circular(radius),
          border:
              Border.all(color: ringColor!, width: AppAvatarGeometry.ringWidth),
        ),
        child: content,
      );
    }

    if (dot) {
      final haloRadius = geometry.dotHaloRadius;
      final center = geometry.dotCenter;
      content = SizedBox(
        width: size,
        height: size,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            content,
            Positioned(
              left: center.dx - haloRadius,
              top: center.dy - haloRadius,
              child: Container(
                padding: const EdgeInsets.all(AppAvatarGeometry.dotHalo),
                decoration: BoxDecoration(
                    color: tokens.surfaceBase, shape: BoxShape.circle),
                child: phone
                    ? AppPresencePhoneMark(size: geometry.markDiameter)
                    : AppStatusDot(
                        status: presence,
                        size: geometry.dotDiameter,
                        backgroundColor: tokens.surfaceBase),
              ),
            ),
          ],
        ),
      );
    }

    // ExcludeSemantics keeps the generated initials text (or a supplied
    // placeholder icon) from merging its own auto-label into this one.
    return Semantics(
      image: true,
      label: semanticLabel ?? (speaking ? '$name, speaking' : name),
      child: ExcludeSemantics(child: content),
    );
  }
}

/// The initials disc. Its text weight is [AppWeights.medium], not
/// [AppWeights.semi]: IBM Plex Mono only ships regular and medium weight
/// files (`design_system/pubspec.yaml`), and this used to be the one call
/// site in the app asking mono for the semibold it never had. With no
/// 600-weight face to match, Skia faked one by thickening medium's strokes,
/// which reads as coarse, blocky glyphs at the small sizes initials render
/// at - most visible on a low-density desktop display, but present on every
/// platform this renders on.
class _Face extends StatelessWidget {
  const _Face({
    required this.round,
    required this.initials,
    required this.tokens,
    required this.geometry,
    required this.withDot,
    required this.tintSource,
    required this.placeholder,
  });

  final bool round;
  final String initials;
  final AppTokens tokens;
  final AppAvatarGeometry geometry;

  /// Whether a presence dot sits on this avatar, which narrows the box the
  /// initials may use.
  final bool withDot;

  /// What [_tintFor] hashes: [AppAvatar.tintKey] resolved against the name.
  final String tintSource;
  final Widget? placeholder;

  @override
  Widget build(BuildContext context) {
    if (!round) {
      return DecoratedBox(
        decoration: BoxDecoration(
            color: tokens.surfaceRaised,
            border: Border.all(color: tokens.borderSubtle)),
        child: Center(child: placeholder),
      );
    }

    final box = geometry.initialsBox(withDot: withDot);
    return ColoredBox(
      color: _tintFor(tintSource),
      child: Center(
        child: initials.isEmpty
            ? null
            : SizedBox(
                width: box.width,
                height: box.height,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    initials,
                    maxLines: 1,
                    softWrap: false,
                    style: TextStyle(
                      fontFamily: AppFonts.mono,
                      fontSize: geometry.initialsFontSize,
                      height: 1,
                      fontWeight: AppWeights.medium,
                      color: _avatarTintInk,
                    ),
                  ),
                ),
              ),
      ),
    );
  }
}
