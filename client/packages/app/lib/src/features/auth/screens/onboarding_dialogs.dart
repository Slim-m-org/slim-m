// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The join flow's manual entry: [ManualServerDialog] takes a bare server
/// address and only gathers and pre-validates it; identity confirmation and
/// the final choice stay with the screen that opened it. The invite entry is
/// `invite_dialog.dart`.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../server_address_input.dart';
import '../../../server_address_reduction.dart';
import '../../../server_scheme_policy.dart';
import '../widgets/server_identity_confirmation.dart';

/// What [ManualServerDialog] hands back: the reduced address and its probe.
typedef ManualServerChoice = ({Uri server, ServerIdentityProbe probe});

/// Connecting to a server by address, with an explicit confirmation step.
///
/// Continue stays busy while `/version` answers, then hands back the address
/// and what it said, so the identity check needs no second request.
class ManualServerDialog extends ConsumerStatefulWidget {
  const ManualServerDialog({super.key});

  @override
  ConsumerState<ManualServerDialog> createState() => ManualServerDialogState();
}

class ManualServerDialogState extends ConsumerState<ManualServerDialog> {
  final _server = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _server.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    final address = parseServerAddress(_server.text);
    if (address == null) {
      setState(() => _error = serverAddressError(_server.text));
      return;
    }

    // See requireSecureScheme for why a LAN address is exempt from this.
    if (requireSecureScheme(address) case final schemeError?) {
      setState(() => _error = schemeError);
      return;
    }
    // Userinfo must never survive into storage; see reduceServerAddress.
    final server = reduceServerAddress(address);
    setState(() => _busy = true);
    final probe = await probeServerIdentity(ref, server);
    if (!mounted) return;
    Navigator.of(
      context,
    ).pop<ManualServerChoice>((server: server, probe: probe));
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final error = _error;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.s16,
        AppSpacing.s16,
        AppSpacing.s16,
        AppSpacing.s16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Connect to a Space',
            style: AppText.body.copyWith(
              color: tokens.textPrimary,
              fontWeight: AppWeights.semi,
            ),
          ),
          const SizedBox(height: AppSpacing.s12),
          AppInput(
            controller: _server,
            placeholder: 'chat.example',
            mono: true,
            autofocus: true,
            invalid: error != null,
            keyboardType: TextInputType.url,
            autocorrect: false,
            semanticLabel: 'Server address',
            onChanged: (_) {
              if (_error != null) setState(() => _error = null);
            },
            onSubmitted: (_) => unawaited(_submit()),
          ),
          const SizedBox(height: AppSpacing.s12),
          // The error takes the note's place, so the dialog does not jump when it appears.
          IndexedStack(
            index: error == null ? 0 : 1,
            children: [
              Text(
                'Whoever runs this Space can read the messages sent through '
                'it. Only connect to one you trust.',
                style: AppText.caption.copyWith(color: tokens.textSecondary),
              ),
              Semantics(
                liveRegion: true,
                child: Text(
                  error ?? '',
                  style: AppText.caption.copyWith(color: tokens.dangerText),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.s12),
          Row(
            children: [
              Expanded(
                child: AppButton(
                  label: 'Cancel',
                  variant: AppButtonVariant.ghost,
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ),
              const SizedBox(width: AppSpacing.s8),
              Expanded(
                child: AppButton(
                  label: 'Continue',
                  variant: AppButtonVariant.primary,
                  busy: _busy,
                  onPressed: () => unawaited(_submit()),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
