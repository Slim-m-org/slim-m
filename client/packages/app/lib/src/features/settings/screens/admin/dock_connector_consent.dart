// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The consent step before a connector is installed or updated (decisions
/// 0067 and 0090): it runs outside the server, what its token will be able to
/// do, and that it reads its settings, secrets included. A sheet on a phone and
/// a centred dialog on a desktop (`docs/design/desktop-vs-mobile.md`, rule 4).
library;

import 'package:flutter/material.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import 'dock_connector_card.dart' show dockConnectorLabels;
import 'dock_host_run_ask.dart';
import 'dock_install_consent.dart' show DockVerifiedBadge;

/// Resolves true once the admin agrees to everything the connector asks for.
Future<bool> showDockConnectorConsent(
  BuildContext context, {
  required api.DockManifest manifest,
  required bool verified,
  required bool isUpdate,
}) async {
  final agreed = await showAppSheet<bool>(
    context,
    scrolls: true,
    builder: (context) => _ConnectorConsent(
      manifest: manifest,
      verified: verified,
      isUpdate: isUpdate,
    ),
  );
  return agreed ?? false;
}

class _ConnectorConsent extends StatefulWidget {
  const _ConnectorConsent({
    required this.manifest,
    required this.verified,
    required this.isUpdate,
  });

  final api.DockManifest manifest;
  final bool verified;
  final bool isUpdate;

  @override
  State<_ConnectorConsent> createState() => _ConnectorConsentState();
}

class _ConnectorConsentState extends State<_ConnectorConsent> {
  bool _understood = false;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final verb = widget.isUpdate ? 'Update' : 'Install';
    final labels = dockConnectorLabels(
      widget.manifest.connectorPermissions ?? 0,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.s16,
        0,
        AppSpacing.s16,
        AppSpacing.s16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '$verb ${widget.manifest.name}?',
                    style: AppText.body.copyWith(
                      color: tokens.textPrimary,
                      fontWeight: AppWeights.semi,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.s8),
                  _standing(tokens),
                  const SizedBox(height: AppSpacing.s12),
                  Text(
                    widget.manifest.hostRun == null
                        ? 'This connector runs outside your server, as a bot '
                              'with its own token. The token can:'
                        : 'This server runs this connector in a sandbox, as a '
                              'bot with its own token. The token can:',
                    style: AppText.body.copyWith(color: tokens.textPrimary),
                  ),
                  const SizedBox(height: AppSpacing.s8),
                  if (labels.isEmpty) _line(tokens, 'Do nothing in your space'),
                  for (final label in labels) _line(tokens, label),
                  const SizedBox(height: AppSpacing.s4),
                  Text(
                    'It also reads the settings you give it, secrets included.',
                    style: AppText.caption.copyWith(
                      color: tokens.textSecondary,
                    ),
                  ),
                  if (widget.manifest.hostRun case final ask?) ...[
                    const SizedBox(height: AppSpacing.s12),
                    DockHostRunAsk(ask: ask),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.s16),
          if (!widget.verified) ...[
            _acknowledgement(tokens),
            const SizedBox(height: AppSpacing.s16),
          ],
          Row(
            children: [
              Expanded(
                child: AppButton(
                  label: 'Cancel',
                  variant: AppButtonVariant.ghost,
                  onPressed: () => Navigator.of(context).pop(false),
                ),
              ),
              const SizedBox(width: AppSpacing.s8),
              Expanded(
                child: AppButton(
                  label: verb,
                  variant: AppButtonVariant.primary,
                  disabled: !widget.verified && !_understood,
                  onPressed: () => Navigator.of(context).pop(true),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _standing(AppTokens tokens) {
    if (widget.verified) {
      return const Align(
        alignment: Alignment.centerLeft,
        child: DockVerifiedBadge(
          message: 'From the official slim-addons registry.',
          tapToShow: true,
        ),
      );
    }
    return AppCallout(
      child: Text(
        'Not verified. slim-m has not reviewed this connector.',
        style: AppText.body.copyWith(color: tokens.warnText),
      ),
    );
  }

  Widget _line(AppTokens tokens, String text) => Padding(
    padding: const EdgeInsets.only(bottom: AppSpacing.s8),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          widget.verified ? AppIcons.info : AppIcons.warning,
          size: AppSizes.icon16,
          color: widget.verified ? tokens.textSecondary : tokens.warnText,
        ),
        const SizedBox(width: AppSpacing.s8),
        Expanded(
          child: Text(
            text,
            style: AppText.body.copyWith(color: tokens.textPrimary),
          ),
        ),
      ],
    ),
  );

  Widget _acknowledgement(AppTokens tokens) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTap: () => setState(() => _understood = !_understood),
    child: Row(
      children: [
        AppToggle(
          value: _understood,
          onChanged: (v) => setState(() => _understood = v),
          semanticLabel: 'I understand what this connector can do',
        ),
        const SizedBox(width: AppSpacing.s12),
        Expanded(
          child: Text(
            'I understand what this connector can do',
            style: AppText.body.copyWith(color: tokens.textPrimary),
          ),
        ),
      ],
    ),
  );
}
