// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The one moment trust-on-first-use asks for a human to compare a server's
/// identity out of band rather than assume it silently.
///
/// Deliberately outside `OnboardingShell`'s numbered stepper: this fires
/// exactly when nothing is pinned yet for the address, which is not a fixed
/// position in the join flow, so it carries no step count rather than a
/// false one.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import 'server_identity_fingerprint.dart';

/// The two rows of four hex groups plus the colour strip, shared by the
/// first-connect confirmation and the identity-changed warning so the two
/// screens read the same code the same way.
class FingerprintDisplay extends StatelessWidget {
  const FingerprintDisplay({super.key, required this.identity});

  final api.ServerIdentity identity;

  /// 17px mono at a wider 0.06em, ported as-is from the source design: the
  /// general code style (13.5px, 0.04em) is tuned for a paragraph of code,
  /// not eight groups meant to be read aloud one at a time.
  static const _groupStyle = TextStyle(
    fontFamily: AppFonts.mono,
    fontSize: 17,
    letterSpacing: 17 * 0.06,
    height: 1.7,
  );

  /// Everything rendered here comes off the wire from a server this screen
  /// exists because you may not trust, so a malformed identity must render
  /// oddly and never throw: a hostile server crashing the screen built to catch
  /// it is the wrong failure.
  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final groups = fingerprintGroupsOf(identity);
    final firstRow = groups.take(4).join('  ');
    final secondRow = groups.skip(4).take(4).join('  ');

    return Column(
      children: [
        Semantics(
          label: 'Identity fingerprint: ${groups.join(' ')}',
          child: ExcludeSemantics(
            child: Column(
              children: [
                Text(
                  firstRow,
                  textAlign: TextAlign.center,
                  style: _groupStyle.copyWith(color: tokens.textPrimary),
                ),
                Text(
                  secondRow,
                  textAlign: TextAlign.center,
                  style: _groupStyle.copyWith(color: tokens.textPrimary),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.s16),
        // Decorative reinforcement of the hex, not independent information,
        // so it stays out of the announced label rather than doubling it.
        ExcludeSemantics(
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (final index in identity.colorStrip)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.s4,
                  ),
                  child: Container(
                    width: AppSizes.icon24,
                    height: AppSizes.icon24,
                    decoration: BoxDecoration(
                      color: AppCanvasColors
                          .cursors[index % AppCanvasColors.cursors.length],
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Shown the first time a client connects to an address: the server's
/// identity has nothing pinned yet to compare against, so this is the only
/// point an out-of-band check (the admin reading the code aloud) can catch an
/// attacker already sitting on the connection. Pins the key and pops `true`
/// once the caller confirms; pops `false` on cancel.
///
/// Never shown for the compiled-in official server, where the app and the
/// server come from one source and there is no separate operator to ask; both
/// doors onto that address pin silently instead. A code this screen asks about
/// is therefore always a server somebody else runs, which is what makes the
/// instruction below a question that has an answer: that operator's own server
/// prints the same eight groups when it starts.
class ServerFingerprintStep extends StatefulWidget {
  const ServerFingerprintStep({
    super.key,
    required this.address,
    required this.identity,
  });

  final Uri address;
  final api.ServerIdentity identity;

  @override
  State<ServerFingerprintStep> createState() => _ServerFingerprintStepState();
}

class _ServerFingerprintStepState extends State<ServerFingerprintStep> {
  bool _copied = false;

  /// Copies the code as the same eight space-separated groups on screen, so
  /// whoever receives it can compare it against their log line character for
  /// character rather than reformatting it first.
  Future<void> _copy() async {
    await Clipboard.setData(
      ClipboardData(text: fingerprintGroupsOf(widget.identity).join(' ')),
    );
    if (!mounted) return;
    setState(() => _copied = true);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final identity = widget.identity;
    final address = widget.address;

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
                Text(
                  'SECURITY CHECK',
                  style: AppText.label.copyWith(color: tokens.textSecondary),
                ),
                const SizedBox(height: AppSpacing.s8),
                Text(
                  'Confirm this server',
                  style: AppText.heading.copyWith(
                    color: tokens.textPrimary,
                    fontWeight: AppWeights.semi,
                  ),
                ),
                const SizedBox(height: AppSpacing.s8),
                Text(
                  address.toString(),
                  style: AppText.caption.copyWith(color: tokens.textSecondary),
                ),
                const SizedBox(height: AppSpacing.s24),
                FingerprintDisplay(identity: identity),
                const SizedBox(height: AppSpacing.s16),
                AppButton(
                  label: _copied ? 'Copied' : 'Copy this code',
                  variant: AppButtonVariant.secondary,
                  full: true,
                  icon: _copied ? AppIcons.check : AppIcons.copy,
                  onPressed: _copy,
                ),
                const SizedBox(height: AppSpacing.s24),
                Text(
                  'Whoever runs ${address.host} sees the same eight groups in '
                  'their server log when it starts. Ask them to read it back '
                  'over something you already trust: in person, or a call you '
                  'placed yourself. Not this connection, and not a message '
                  'that arrived through it.',
                  style: AppText.body.copyWith(color: tokens.textSecondary),
                ),
                const SizedBox(height: AppSpacing.s16),
                const AppCallout(
                  tone: AppCalloutTone.warn,
                  child: Text(
                    'This only protects connections after this one: someone '
                    'already sitting on this connection could show you their '
                    'own key just as convincingly.',
                  ),
                ),
                const SizedBox(height: AppSpacing.s24),
                AppButton(
                  label: 'It matches - continue',
                  variant: AppButtonVariant.primary,
                  full: true,
                  onPressed: () => Navigator.of(context).pop(true),
                ),
                const SizedBox(height: AppSpacing.s12),
                AppButton(
                  label: 'Cancel',
                  variant: AppButtonVariant.ghost,
                  full: true,
                  onPressed: () => Navigator.of(context).pop(false),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
