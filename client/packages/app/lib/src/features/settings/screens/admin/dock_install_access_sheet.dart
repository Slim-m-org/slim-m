// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The access switches a first install asks about, in a sheet opened by the
/// Install button, so the module's page before install reads like a store
/// page: what it is and what it adds, with the questions asked at the moment
/// they matter. Once installed, the same switches live on the page.
library;

import 'package:flutter/material.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import 'dock_host_access_card.dart';

/// What the admin chose in the sheet.
typedef DockAccessChoice = ({Set<String> approved, bool localNetwork});

/// Asks which of [manifest]'s powers to grant before the first install; null when cancelled.
Future<DockAccessChoice?> showDockInstallAccessSheet(
  BuildContext context, {
  required api.DockManifest manifest,
  required Set<String> approved,
  required bool localNetwork,
}) => showAppSheet<DockAccessChoice>(
  context,
  scrolls: true,
  builder: (context) => _AccessSheet(
    manifest: manifest,
    approved: approved,
    localNetwork: localNetwork,
  ),
);

class _AccessSheet extends StatefulWidget {
  const _AccessSheet({
    required this.manifest,
    required this.approved,
    required this.localNetwork,
  });

  final api.DockManifest manifest;
  final Set<String> approved;
  final bool localNetwork;

  @override
  State<_AccessSheet> createState() => _AccessSheetState();
}

class _AccessSheetState extends State<_AccessSheet> {
  late final Set<String> _approved = {...widget.approved};
  late bool _localNetwork = widget.localNetwork;

  void _toggle(String capability, bool on) => setState(() {
    on ? _approved.add(capability) : _approved.remove(capability);
    if (capability == api.kNetFetchCapability) _localNetwork = false;
  });

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
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
          Text(
            'Install ${widget.manifest.name}',
            style: AppText.body.copyWith(
              color: tokens.textPrimary,
              fontWeight: AppWeights.semi,
            ),
          ),
          const SizedBox(height: AppSpacing.s4),
          Text(
            'Choose what it may do. You can change this later on its page.',
            style: AppText.caption.copyWith(color: tokens.textSecondary),
          ),
          const SizedBox(height: AppSpacing.s12),
          Flexible(
            child: SingleChildScrollView(
              child: DockHostAccessCard(
                manifest: widget.manifest,
                approved: _approved,
                onChanged: _toggle,
                moduleName: widget.manifest.name,
                localNetworkApproved: _localNetwork,
                onLocalNetworkChanged: (on) =>
                    setState(() => _localNetwork = on),
                enabled: true,
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.s16),
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
                  key: dockInstallAccessConfirmKey,
                  label: 'Install',
                  variant: AppButtonVariant.primary,
                  onPressed: () => Navigator.of(
                    context,
                  ).pop((approved: _approved, localNetwork: _localNetwork)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

const dockInstallAccessConfirmKey = Key('dock-install-access-confirm');
