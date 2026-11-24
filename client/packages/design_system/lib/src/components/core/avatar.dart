// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The user picture: round for a person, square for a non-human author (a
/// webhook, a CI bot).
///
/// A round avatar gets a tinted disc (a deep shade of the person's own colour,
/// or one from a closed six-colour list) and mono initials; a square one gets
/// none of that; the shape difference is what marks a non-human author, since
/// it survives a screenshot the way a colour convention alone would not.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../app_metrics.dart';
import '../../app_tokens.dart';
import '../../app_typography.dart';
import '../../colour_contrast.dart';
import '../../stable_index.dart';
import 'avatar_badge.dart';
import 'avatar_geometry.dart';
import 'avatar_mark_slot.dart';
import 'avatar_shaped_image.dart';
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

/// The disc colour for [source] when there is no person's colour to draw from, the same one wherever it is drawn.
Color avatarTintFor(String source) =>
    _avatarTints[stableIndexFor(source, _avatarTints.length)];

/// One letter or digit for each of the first two words ("Nick Conn" NC, "Tester" T); a single word
/// splits on its symbols ("nick.conn" NC). Public as the one rule every surface shares.
String initialsFor(String name) {
  var words = _initialWords(name.split(_space));
  if (words.length < 2) words = _initialWords(name.split(_notLetterOrDigit));
  return words.take(2).map(_firstRune).join().toUpperCase();
}

List<String> _initialWords(List<String> parts) => [
      for (final part in parts)
        if (part.replaceAll(_notLetterOrDigit, '') case final word
            when word.isNotEmpty)
          word,
    ];

String _firstRune(String word) => String.fromCharCode(word.runes.first);

final RegExp _space = RegExp(r'\s+');

/// Letters and digits in any script stay; symbols and punctuation go.
final RegExp _notLetterOrDigit = RegExp(r'[^\p{L}\p{N}]', unicode: true);

/// Light ink for every disc tint; every themed text colour inverts and would
/// go illegible on them in dark.
const Color avatarTintInk = Color(0xFFFFFFFF);

/// The disc for a person whose colour is [colour]: its hue, muted and deepened until
/// [avatarTintInk] reads on it at [_tintInkRatio], the same in either theme.
Color avatarTintFromColour(Color colour) {
  final hsl = HSLColor.fromColor(colour);
  final saturation = math.min(hsl.saturation, _tintSaturationCap);
  for (var step = 0;; step++) {
    final lightness = math.max(0.0, _tintLightness - step * 0.01);
    final shade = HSLColor.fromAHSL(1, hsl.hue, saturation, lightness);
    if (contrastRatio(avatarTintInk, shade.toColor()) >= _tintInkRatio) {
      return shade.toColor();
    }
  }
}

const double _tintSaturationCap = 0.45;
const double _tintLightness = 0.40;

/// Above AA's 4.5 so the bright hues deepen to about the depth of the dark ones.
const double _tintInkRatio = 5.5;

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
    this.tintColor,
    this.image,
    this.size = AppAvatarSize.s36,
    this.shape = AppAvatarShape.circle,
    this.status,
    this.mobileOnly = false,
    this.badge,
    this.speaking = false,
    this.ringColor,
    this.placeholder,
    this.semanticLabel,
    this.speakingLabel = 'speaking',
    this.surfaceColor,
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

  /// The person's own colour; the disc is drawn in [avatarTintFromColour] of
  /// it instead of a [tintKey] hash. Ignored on a square avatar.
  final Color? tintColor;
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

  /// Drawn in the dot's place when set, and [status] is then not drawn at all.
  final AppAvatarBadge? badge;

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

  /// How the accessible name reads the [speaking] ring, for a surface where
  /// it means something other than speech; the presence word still follows.
  final String speakingLabel;

  /// A caller-supplied ring (a fingerprint-confirmation colour strip, for
  /// instance), drawn when [speaking] is false.
  final Color? ringColor;

  /// Content for a [AppAvatarShape.square] avatar with no [image]: a square
  /// avatar never shows generated initials, since a bot's identity is its
  /// icon, not a name hash.
  final Widget? placeholder;

  final String? semanticLabel;

  /// What the avatar sits on, when that is not [AppTokens.surfaceBase]: the
  /// marks punched out of the dot and the speaking glyph are drawn in it.
  final Color? surfaceColor;

  /// The name, then whatever the ring and the dot show, so a screen reader
  /// hears what a sighted viewer sees.
  String _label(String? markWord) =>
      '$name${speaking ? ', $speakingLabel' : ''}'
      '${markWord == null ? '' : ', $markWord'}';

  Color get _tint => switch (tintColor) {
        final colour? => avatarTintFromColour(colour),
        null => avatarTintFor(tintKey ?? name),
      };

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final round = shape == AppAvatarShape.circle;
    final radius = round ? size / 2 : AppRadii.control;
    final initials = round ? initialsFor(name) : '';
    final presence = status;
    final marked = badge != null;
    final dot = marked || (presence != null && presence != AppPresence.unknown);
    final phone =
        !marked && dot && mobileOnly && presence == AppPresence.online;
    final geometry = AppAvatarGeometry(size, phone: phone, badge: marked);
    final surface = surfaceColor ?? tokens.surfaceBase;

    Widget content = image == null
        ? _Face(
            round: round,
            initials: initials,
            tokens: tokens,
            geometry: geometry,
            withDot: dot,
            tint: _tint,
            placeholder: placeholder)
        : AppShapedImage(
            image: image!,
            size: size,
            radius: radius,
            errorBuilder: (context) => _Face(
              round: round,
              initials: initials,
              tokens: tokens,
              geometry: geometry,
              withDot: dot,
              tint: _tint,
              placeholder: placeholder,
            ),
          );

    // Shaped by its own fill, not a clip: see AppShapedImage for why.
    content = SizedBox(width: size, height: size, child: content);

    // A foreground overlay, not a bordered wrapper, so layout size never moves.
    if (speaking) {
      content = AppSpeakingRing(
        color: tokens.accentFill,
        size: size,
        round: round,
        radius: radius,
        glyphBackgroundColor: surface,
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
      content = AppAvatarMarkSlot(
        geometry: geometry,
        mark: switch (badge) {
          final badge? =>
            AppAvatarBadgeMark(badge: badge, size: geometry.markDiameter),
          null when phone => AppPresencePhoneMark(size: geometry.markDiameter),
          null => AppStatusDot(
              status: presence!,
              size: geometry.dotDiameter,
              backgroundColor: surface),
        },
        child: content,
      );
    }

    // ExcludeSemantics keeps the generated initials text (or a supplied
    // placeholder icon) from merging its own auto-label into this one.
    return Semantics(
      image: true,
      label:
          semanticLabel ?? _label(badge?.word ?? (dot ? presence?.word : null)),
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
    required this.tint,
    required this.placeholder,
  });

  final bool round;
  final String initials;
  final AppTokens tokens;
  final AppAvatarGeometry geometry;

  /// Whether a presence dot sits on this avatar, which narrows the box the
  /// initials may use.
  final bool withDot;

  /// The disc colour, resolved by [AppAvatar].
  final Color tint;
  final Widget? placeholder;

  @override
  Widget build(BuildContext context) {
    if (!round) {
      return DecoratedBox(
        decoration: BoxDecoration(
            color: tokens.surfaceRaised,
            borderRadius: BorderRadius.circular(AppRadii.control),
            border: Border.all(color: tokens.borderSubtle)),
        child: Center(child: placeholder),
      );
    }

    final box = geometry.initialsBox(withDot: withDot);
    return AppShapedDisc(
      color: tint,
      size: geometry.size,
      radius: geometry.size / 2,
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
                      color: avatarTintInk,
                    ),
                  ),
                ),
              ),
      ),
    );
  }
}
