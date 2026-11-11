// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A later connection whose key does not match what was pinned before. First
/// connects pin silently, so this is the one moment trust-on-first-use speaks,
/// and it speaks bluntly.
library;

import 'package:flutter/material.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import 'server_identity_fingerprint.dart';

/// Shown when the address answers with a different key than the one already
/// pinned for it. Pops `true` only if the person trusts the new server, `false`
/// on going back. A caller with no route to pop passes [onDecision].
class ServerIdentityChangedStep extends StatelessWidget {
  const ServerIdentityChangedStep({
    super.key,
    required this.address,
    required this.identity,
    this.onDecision,
  });

  final Uri address;

  /// What the server presents now; null when it presents no identity at all.
  final api.ServerIdentity? identity;
  final void Function(bool trusted)? onDecision;

  void _decide(BuildContext context, bool trusted) {
    if (onDecision case final decide?) return decide(trusted);
    Navigator.of(context).pop(trusted);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final words = identity == null
        ? const <String>[]
        : fingerprintWordsOf(identity!);

    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(AppSpacing.s24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: Icon(
                    AppIcons.warning,
                    size: AppSizes.icon24,
                    color: tokens.dangerText,
                  ),
                ),
                const SizedBox(height: AppSpacing.s12),
                Text(
                  "This isn't the server you joined before",
                  style: AppText.heading.copyWith(
                    color: tokens.dangerText,
                    fontWeight: AppWeights.semi,
                  ),
                ),
                const SizedBox(height: AppSpacing.s8),
                Text(
                  address.host,
                  style: AppText.caption.copyWith(
                    color: tokens.textSecondary,
                    fontFamily: AppFonts.mono,
                  ),
                ),
                const SizedBox(height: AppSpacing.s16),
                Text(
                  words.isEmpty
                      ? 'It no longer proves who it is. Someone may be '
                            'standing between you and it.'
                      : 'Someone may be standing between you and it. Ask the '
                            'admin to read you its words.',
                  style: AppText.body.copyWith(color: tokens.textSecondary),
                ),
                if (words.isNotEmpty) ...[
                  const SizedBox(height: AppSpacing.s24),
                  _Words(words: words),
                ],
                const SizedBox(height: AppSpacing.s32),
                AppButton(
                  label: 'Go back',
                  variant: AppButtonVariant.primary,
                  full: true,
                  onPressed: () => _decide(context, false),
                ),
                const SizedBox(height: AppSpacing.s12),
                AppButton(
                  label: 'Trust the new server',
                  variant: AppButtonVariant.danger,
                  full: true,
                  onPressed: () => _decide(context, true),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The five words, one per line so each can be matched against what the admin
/// says without losing the place.
class _Words extends StatelessWidget {
  const _Words({required this.words});

  final List<String> words;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Semantics(
      label: 'New server words: ${words.join(' ')}',
      child: ExcludeSemantics(
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.s16),
          decoration: BoxDecoration(
            color: tokens.surfaceRaised,
            border: Border.all(color: tokens.borderSubtle),
            borderRadius: BorderRadius.circular(AppRadii.card),
          ),
          child: Column(
            children: [
              for (final word in words)
                Text(
                  word,
                  textAlign: TextAlign.center,
                  style: AppText.heading.copyWith(
                    color: tokens.textPrimary,
                    fontFamily: AppFonts.mono,
                    height: 1.5,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
