// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The consent step before a module is installed or updated
/// (docs/decisions/0067-module-install-consent.md): what it can do in plain
/// words, then an explicit yes. A module from an unreviewed source needs the
/// admin to tick that they understand; a verified one is a lighter list and
/// the Install press is the yes.
library;

import 'package:flutter/material.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import 'dock_host_access_card.dart';
import 'dock_limits_card.dart';

/// Official-registry modules are verified; every community source is not.
bool dockIsVerified(String? source) => source == null || source == 'official';

/// The capabilities [manifest] asks for that the install being replaced did
/// not, with a first install asking for all of them.
List<String> newConsentCapabilities(
  api.DockManifest manifest,
  api.InstalledDockModule? installed,
) {
  final had = installed?.approvedCapabilities ?? const <String>[];
  return [
    for (final capability in grantableHostCapabilities(manifest.capabilities))
      if (!had.contains(capability) ||
          _hostsChanged(capability, manifest, installed))
        capability,
  ];
}

/// An update that names different hosts drops the old `net.fetch` approval.
bool _hostsChanged(
  String capability,
  api.DockManifest manifest,
  api.InstalledDockModule? installed,
) =>
    capability == 'net.fetch' &&
    installed != null &&
    installed.approvedHostCapabilities.contains(capability) &&
    !dockSameHosts(installed.networkHosts, manifest.network?.hosts ?? const []);

/// Whether two host lists name the same hosts, in any order.
bool dockSameHosts(List<String> a, List<String> b) =>
    a.length == b.length && a.toSet().containsAll(b);

/// Whether pressing Install should stop at the consent step first.
bool dockNeedsConsent({
  required List<String> newCapabilities,
  required bool verified,
  required bool firstInstall,
}) => newCapabilities.isNotEmpty || (firstInstall && !verified);

/// A "Verified" mark for a module from the official registry.
class DockVerifiedBadge extends StatelessWidget {
  const DockVerifiedBadge({super.key});

  @override
  Widget build(BuildContext context) => const AppBadge(
    variant: AppBadgeVariant.role,
    label: 'Verified',
    icon: AppIcons.verified,
  );
}

/// Resolves true once the admin agrees, false when they back out.
Future<bool> showDockInstallConsent(
  BuildContext context, {
  required api.DockManifest manifest,
  required List<String> capabilities,
  required bool verified,
  required bool isUpdate,
  bool localNetwork = false,
}) async {
  final agreed = await showAppSheet<bool>(
    context,
    scrolls: true,
    builder: (context) => _ConsentSheet(
      manifest: manifest,
      capabilities: capabilities,
      verified: verified,
      isUpdate: isUpdate,
      localNetwork: localNetwork,
    ),
  );
  return agreed ?? false;
}

class _ConsentSheet extends StatefulWidget {
  const _ConsentSheet({
    required this.manifest,
    required this.capabilities,
    required this.verified,
    required this.isUpdate,
    required this.localNetwork,
  });

  final api.DockManifest manifest;
  final bool localNetwork;
  final List<String> capabilities;
  final bool verified;
  final bool isUpdate;

  @override
  State<_ConsentSheet> createState() => _ConsentSheetState();
}

class _ConsentSheetState extends State<_ConsentSheet> {
  bool _understood = false;

  bool get _needsTick => !widget.verified && widget.capabilities.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final verb = widget.isUpdate ? 'Update' : 'Install';
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
          Flexible(child: SingleChildScrollView(child: _details(tokens, verb))),
          const SizedBox(height: AppSpacing.s16),
          if (_needsTick) ...[
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
                  disabled: _needsTick && !_understood,
                  onPressed: () => Navigator.of(context).pop(true),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _details(AppTokens tokens, String verb) => Column(
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
      if (widget.capabilities.isNotEmpty) ...[
        Text(
          widget.isUpdate
              ? 'This version asks for new access. It can:'
              : 'This module can:',
          style: AppText.body.copyWith(color: tokens.textPrimary),
        ),
        const SizedBox(height: AppSpacing.s8),
        for (final capability in widget.capabilities)
          _CapabilityLine(
            text: dockCapabilityWarning(
              capability,
              details: dockCapabilityDetails(widget.manifest, capability),
            )!,
            verified: widget.verified,
          ),
        if (widget.localNetwork && widget.capabilities.contains('net.fetch'))
          _CapabilityLine(
            text: dockLocalNetworkWarning,
            verified: widget.verified,
          ),
      ] else
        Text(
          'It runs code on your server with no access to your space.',
          style: AppText.body.copyWith(color: tokens.textSecondary),
        ),
      const SizedBox(height: AppSpacing.s8),
      Text(
        DockLimitsCard.summary(widget.manifest.runtime.limits),
        style: AppText.caption.copyWith(color: tokens.textSecondary),
      ),
    ],
  );

  Widget _standing(AppTokens tokens) {
    if (widget.verified) {
      return Wrap(
        spacing: AppSpacing.s8,
        runSpacing: AppSpacing.s4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          const DockVerifiedBadge(),
          Text(
            'From the official slim-addons registry.',
            style: AppText.caption.copyWith(color: tokens.textSecondary),
          ),
        ],
      );
    }
    return AppCallout(
      child: Text(
        'Not verified. slim-m has not reviewed this module.',
        style: AppText.body.copyWith(color: tokens.warnText),
      ),
    );
  }

  Widget _acknowledgement(AppTokens tokens) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTap: () => setState(() => _understood = !_understood),
    child: Row(
      children: [
        AppToggle(
          value: _understood,
          onChanged: (v) => setState(() => _understood = v),
          semanticLabel: 'I understand what this module can do',
        ),
        const SizedBox(width: AppSpacing.s12),
        Expanded(
          child: Text(
            'I understand what this module can do',
            style: AppText.body.copyWith(color: tokens.textPrimary),
          ),
        ),
      ],
    ),
  );
}

class _CapabilityLine extends StatelessWidget {
  const _CapabilityLine({required this.text, required this.verified});

  final String text;
  final bool verified;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.s8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            verified ? AppIcons.info : AppIcons.warning,
            size: AppSizes.icon16,
            color: verified ? tokens.textSecondary : tokens.warnText,
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
  }
}
