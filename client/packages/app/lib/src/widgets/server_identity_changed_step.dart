// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The other half of pinning a server's identity: a later connection whose
/// key does not match what was pinned before. Trust-on-first-use exists to
/// make exactly this visible, so nothing here may read like the routine
/// first-connect confirmation it is not.
library;

import 'package:flutter/material.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import 'server_fingerprint_step.dart';

/// Shown when the address answers with a different key than the one already
/// pinned for it. Requires an explicit acknowledgement before the one action
/// that re-pins the new key even unlocks, so it cannot be tapped through the
/// way the ordinary confirmation can. Pops `true` only if that action fires;
/// `false` on cancel. A caller with no route to pop passes [onDecision].
class ServerIdentityChangedStep extends StatefulWidget {
  const ServerIdentityChangedStep({
    super.key,
    required this.address,
    required this.identity,
    this.onDecision,
  });

  final Uri address;

  /// The key the server presents now; null when it presented none, which
  /// leaves nothing to compare or trust.
  final api.ServerIdentity? identity;
  final void Function(bool trusted)? onDecision;

  @override
  State<ServerIdentityChangedStep> createState() =>
      _ServerIdentityChangedStepState();
}

class _ServerIdentityChangedStepState extends State<ServerIdentityChangedStep> {
  bool _acknowledged = false;

  void _decide(bool trusted) {
    if (widget.onDecision case final decide?) return decide(trusted);
    Navigator.of(context).pop(trusted);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final identity = widget.identity;

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
                  identity == null
                      ? 'This server stopped proving its identity'
                      : "This server's identity changed",
                  style: AppText.heading.copyWith(
                    color: tokens.dangerText,
                    fontWeight: AppWeights.semi,
                  ),
                ),
                const SizedBox(height: AppSpacing.s8),
                Text(
                  widget.address.toString(),
                  style: AppText.caption.copyWith(color: tokens.textSecondary),
                ),
                const SizedBox(height: AppSpacing.s24),
                AppCallout(
                  tone: AppCalloutTone.warn,
                  child: Text(
                    identity == null
                        ? 'This app pinned a key for this address, but the '
                              'server answered without one, so there is no way '
                              'to check it is the server trusted before. Ask '
                              'whoever runs it what changed.'
                        : 'The key this server presents does not match the one '
                              'pinned the last time this app connected here. That can '
                              'be an honest change, a re-key or a move to new '
                              'hosting, or it can mean this connection no longer '
                              'reaches the server that was trusted before. Confirm '
                              'the code below with whoever runs it before trusting '
                              'it again.',
                  ),
                ),
                const SizedBox(height: AppSpacing.s24),
                if (identity != null) ...[
                  FingerprintDisplay(identity: identity),
                  const SizedBox(height: AppSpacing.s24),
                  CheckboxListTile(
                    value: _acknowledged,
                    onChanged: (v) =>
                        setState(() => _acknowledged = v ?? false),
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    title: Text(
                      'I have confirmed this new code with whoever runs this '
                      'server.',
                      style: AppText.caption.copyWith(
                        color: tokens.textPrimary,
                      ),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.s12),
                  AppButton(
                    label: 'Trust the new identity',
                    variant: AppButtonVariant.danger,
                    full: true,
                    disabled: !_acknowledged,
                    onPressed: () => _decide(true),
                  ),
                  const SizedBox(height: AppSpacing.s12),
                ],
                AppButton(
                  label: 'Cancel',
                  variant: AppButtonVariant.secondary,
                  full: true,
                  onPressed: () => _decide(false),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
