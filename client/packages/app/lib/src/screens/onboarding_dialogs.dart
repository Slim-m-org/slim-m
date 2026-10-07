// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The join flow's two entry dialogs, split from `onboarding_screen.dart`
/// when that file crossed the size ceiling: [InviteDialog] redeems a code
/// (or a pasted/tapped invite link), [ManualServerDialog] takes a bare
/// server address. Both only gather and pre-validate input; identity
/// confirmation and the final choice stay with the screen that opened them.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../api_failure.dart';
import '../invite_link.dart';
import '../providers/providers.dart';
import '../server_address_reduction.dart';
import '../server_scheme_policy.dart';

/// Redeeming an invite: check the code against the server before asking anyone
/// to fill in a signup form, and accept the terms at the point of joining.
class InviteDialog extends ConsumerStatefulWidget {
  const InviteDialog({this.initial, super.key});

  /// Prefill from a tapped invite link. Fills the fields exactly the way a
  /// paste does - every check a typed address clears still runs on it.
  final ({Uri server, String code})? initial;

  @override
  ConsumerState<InviteDialog> createState() => InviteDialogState();
}

class InviteDialogState extends ConsumerState<InviteDialog> {
  late final _server = TextEditingController(
    text: widget.initial?.server.toString() ?? '',
  );
  late final _code = TextEditingController(text: widget.initial?.code ?? '');
  bool _accepted = false;
  bool _busy = false;
  String? _error;

  /// True once a link has named the server, so the address is not asked for
  /// again; "Use a different server" brings the field back.
  late bool _serverFromLink = widget.initial != null;

  @override
  void dispose() {
    _server.dispose();
    _code.dispose();
    super.dispose();
  }

  /// Splits a pasted invite link across both fields, so somebody handed one
  /// string does not have to pull it apart by hand.
  ///
  /// Only fills the fields in. The server it names is exactly as untrusted as
  /// one typed here, so [_verify]'s scheme check, address reduction and live
  /// probe all still run on it - a link must not become a way past guards
  /// that typing has to clear. Anything that is not a link is left alone,
  /// since a bare code pasted into the code field is already correct.
  void _absorbPastedLink(String text) {
    final invite = parseInviteLink(text);
    if (invite == null) return;
    setState(() {
      _server.text = invite.server.toString();
      _code.text = invite.code;
      _serverFromLink = true;
      _error = null;
    });
  }

  String _joiningHost() {
    final host = Uri.tryParse(_server.text.trim())?.host ?? '';
    return host.isEmpty ? _server.text.trim() : host;
  }

  Future<void> _verify() async {
    if (looksLikeWebAddress(_code.text)) {
      setState(
        () => _error =
            'That looks like a web address. Paste an invite link that '
            'starts with slimm://join, or just the code.',
      );
      return;
    }
    final address = Uri.tryParse(_server.text.trim());
    if (address == null || !address.hasScheme || address.host.isEmpty) {
      setState(() => _error = 'That does not look like a server address.');
      return;
    }
    if (requireSecureScheme(address) case final schemeError?) {
      setState(() => _error = schemeError);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });

    // Userinfo must never ride along on the probe or persist; see reduceServerAddress.
    final reduced = reduceServerAddress(address);
    // The probe seam confirmServerIdentity uses, so a test can fake this untrusted transport the same way.
    final client = ref.read(probeApiProvider)(reduced);
    try {
      final check = await client.checkInvite(_code.text.trim());
      if (!mounted) return;
      if (check is api.InviteUnusable) {
        /// Deliberately vague, and it has to stay that way: the server answers
        /// expired, spent, revoked and never-issued identically so codes cannot
        /// be mined, and naming a reason here would undo that from the client
        /// side by telling an attacker which of the four they hit.
        setState(
          () => _error =
              'That code is not usable. It may have expired '
              'or already been used.',
        );
        return;
      }
      if (mounted) {
        Navigator.of(context).pop((reduced, _code.text.trim()));
      }
    } on api.ApiException catch (e) {
      if (!mounted) return;
      setState(
        () => _error = e is api.TransportException
            ? 'Could not reach that server.'
            : 'The server refused that. ${sentenceCase(e.message)}',
      );
    } finally {
      client.close();
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Padding(
      padding: EdgeInsets.fromLTRB(
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
            'Redeem an invite',
            style: AppText.body.copyWith(
              color: tokens.textPrimary,
              fontWeight: AppWeights.semi,
            ),
          ),
          const SizedBox(height: AppSpacing.s12),
          if (_serverFromLink) ...[
            Text(
              'Joining ${_joiningHost()}',
              style: AppText.code.copyWith(color: tokens.textSecondary),
            ),
            const SizedBox(height: AppSpacing.s12),
          ] else ...[
            AppInput(
              controller: _server,
              placeholder: 'https://chat.example',
              keyboardType: TextInputType.url,
              semanticLabel: 'Server',
              onChanged: _absorbPastedLink,
            ),
            const SizedBox(height: AppSpacing.s12),
          ],
          AppInput(
            controller: _code,
            // Either field takes a whole link, because somebody pasting one has no reason to know which half it is.
            placeholder: 'Invite code, or paste an invite link',
            semanticLabel: 'Invite code',
            onChanged: _absorbPastedLink,
          ),
          const SizedBox(height: AppSpacing.s12),
          // Terms are accepted at the point of joining - where the decision actually is, not buried in settings.
          CheckboxListTile(
            value: _accepted,
            onChanged: (v) => setState(() => _accepted = v ?? false),
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            title: Text(
              'I accept the terms of use for this Space.',
              style: AppText.caption.copyWith(color: tokens.textSecondary),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: AppSpacing.s4),
            AppErrorState(message: _error!),
          ],
          const SizedBox(height: AppSpacing.s12),
          if (_serverFromLink) ...[
            Align(
              alignment: Alignment.centerLeft,
              child: AppButton(
                label: 'Use a different server',
                variant: AppButtonVariant.ghost,
                onPressed: () => setState(() => _serverFromLink = false),
              ),
            ),
            const SizedBox(height: AppSpacing.s8),
          ],
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
                  label: _busy ? 'Checking...' : 'Continue',
                  variant: AppButtonVariant.primary,
                  disabled: _busy || !_accepted,
                  onPressed: _verify,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Connecting to a server by address, with an explicit confirmation step.
class ManualServerDialog extends StatefulWidget {
  const ManualServerDialog({super.key});

  @override
  State<ManualServerDialog> createState() => ManualServerDialogState();
}

class ManualServerDialogState extends State<ManualServerDialog> {
  final _server = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _server.dispose();
    super.dispose();
  }

  void _submit() {
    final address = Uri.tryParse(_server.text.trim());
    if (address == null || !address.hasScheme || address.host.isEmpty) {
      setState(() => _error = 'That does not look like a server address.');
      return;
    }

    // See requireSecureScheme for why a LAN address is exempt from this.
    if (requireSecureScheme(address) case final schemeError?) {
      setState(() => _error = schemeError);
      return;
    }
    // Userinfo must never survive into storage; see reduceServerAddress.
    Navigator.of(context).pop(reduceServerAddress(address));
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Padding(
      padding: EdgeInsets.fromLTRB(
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
            placeholder: 'https://chat.example',
            autofocus: true,
            keyboardType: TextInputType.url,
            semanticLabel: 'Server address',
            onSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: AppSpacing.s12),
          Text(
            'Whoever runs this Space can read the messages sent through it. '
            'Only connect to one you trust.',
            style: AppText.caption.copyWith(color: tokens.textSecondary),
          ),
          if (_error != null) ...[
            const SizedBox(height: AppSpacing.s12),
            AppErrorState(message: _error!),
          ],
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
                  onPressed: _submit,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
