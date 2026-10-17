// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Space a pre-session form is about, and how far its identity can be
/// trusted. Split from `onboarding_shell.dart` because the chip is a
/// statement about a server, not about the frame it happens to sit in.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

/// How a server's identity compares against whatever this app already
/// pinned for that address. Three states, not a boolean, because "no pin
/// exists yet" and "the pin does not match" are opposite risk levels and
/// must never share one rendering.
enum ServerIdentityStatus {
  /// The fetched key matches the pin. The tick is about this, and only
  /// this: reaching a server says who answered, not that it is the one
  /// trusted last time.
  confirmed,

  /// Nothing is pinned yet, or the server is too old to report an identity
  /// at all (`Version.identity == null`). Neither is a safety claim in
  /// either direction, so this renders as quietly as an unasked question.
  unknown,

  /// The fetched key does not match the pin. Must read louder than
  /// [unknown] and never as a neutral absence of information: this is the
  /// one state trust-on-first-use exists to make visible.
  mismatch,
}

/// The Space a form is about: its initials, its name and its host, with a
/// glyph for how its identity compares against what this app already
/// pinned.
///
/// Shown only once `/version` has answered, because until then the only
/// honest thing to say about a typed address is nothing.
class ServerIdentityChip extends StatelessWidget {
  const ServerIdentityChip({
    super.key,
    required this.spaceName,
    required this.host,
    this.status = ServerIdentityStatus.unknown,
  });

  final String spaceName;
  final String host;
  final ServerIdentityStatus status;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final stripped = initialsFor(spaceName);
    final initials = stripped.isEmpty ? '?' : stripped;

    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.s16),
      child: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: tokens.surfaceSunken,
              border: Border.all(color: tokens.borderSubtle),
              borderRadius: BorderRadius.circular(AppRadii.control),
            ),
            child: Text(
              initials,
              style: AppText.code.copyWith(
                fontSize: 11,
                color: tokens.textSecondary,
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.s12),
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: spaceName,
                    style: TextStyle(color: tokens.textPrimary),
                  ),
                  TextSpan(
                    text: '  $host',
                    style: AppText.code.copyWith(
                      fontSize: 12,
                      color: tokens.textSecondary,
                    ),
                  ),
                ],
              ),
              style: AppText.caption,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: AppSpacing.s8),
          _IdentityStatusGlyph(status: status),
        ],
      ),
    );
  }
}

/// The tick, its louder mismatch counterpart, or nothing - each with a
/// visible word beside it, not only a screen-reader label.
///
/// This is a security-relevant signal (trust-on-first-use's one visible
/// cue for whether a server is the one trusted last time), so a sighted,
/// non-screen-reader user needs on-screen words for it too, not just a
/// tooltip nobody has a reason to hover a 16px glyph for. The full
/// semantic sentence stays on the [Semantics] wrapper for a screen reader;
/// the short visible word is `excludeSemantics`-scoped so nothing is
/// announced twice.
class _IdentityStatusGlyph extends StatelessWidget {
  const _IdentityStatusGlyph({required this.status});

  final ServerIdentityStatus status;

  static const _labels = {
    ServerIdentityStatus.confirmed:
        'Identity confirmed: matches the key this app pinned before.',
    ServerIdentityStatus.unknown: 'Identity not yet confirmed.',
    ServerIdentityStatus.mismatch:
        "Identity does not match the key this app pinned before. This "
        'server may not be the one trusted last time.',
  };

  /// The short visible word beside the glyph. Unknown renders neither an
  /// icon nor a word, deliberately: it is not yet a claim in either
  /// direction, so it stays as quiet as an unasked question.
  static const _visibleText = {
    ServerIdentityStatus.confirmed: 'Confirmed',
    ServerIdentityStatus.mismatch: 'Changed',
  };

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final (icon, color) = switch (status) {
      ServerIdentityStatus.confirmed => (AppIcons.check, tokens.accent),
      ServerIdentityStatus.unknown => (null, null),
      ServerIdentityStatus.mismatch => (AppIcons.danger, tokens.dangerText),
    };
    final text = _visibleText[status];

    return Semantics(
      label: _labels[status],
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: AppSizes.icon16,
            height: AppSizes.icon16,
            child: icon == null
                ? null
                : Icon(icon, size: AppSizes.icon16, color: color),
          ),
          if (text != null) ...[
            const SizedBox(width: AppSpacing.s4),
            Text(
              text,
              style: AppText.caption.copyWith(
                color: color,
                fontWeight: AppWeights.semi,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
