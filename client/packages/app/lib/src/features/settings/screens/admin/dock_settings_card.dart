// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// "Settings": the form for the settings an installed module declares, loaded
/// when its Dock page opens. Hidden when it declares none.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../../../providers/providers.dart';
import '../../../../widgets/run_guarded.dart';
import '../../widgets/admin/module_settings_form.dart';
import '../../widgets/settings_section_header.dart';

class DockSettingsCard extends ConsumerStatefulWidget {
  const DockSettingsCard({super.key, required this.moduleId});

  final String moduleId;

  @override
  ConsumerState<DockSettingsCard> createState() => _DockSettingsCardState();
}

class _DockSettingsCardState extends ConsumerState<DockSettingsCard>
    with GuardedActionState<DockSettingsCard> {
  api.ModuleSettingsDoc? _doc;
  String? _loadError;
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    final ok = await guard(
      whatFailed: 'Could not load the settings',
      action: () async {
        final doc = await ref.read(apiProvider).moduleSettings(widget.moduleId);
        if (mounted) _doc = doc;
      },
    );
    if (!mounted) return;
    setState(() {
      _loading = false;
      _loadError = ok ? null : actionError;
    });
  }

  Future<void> _save(Map<String, Object?> values) async {
    setState(() => _saving = true);
    await guard(
      whatFailed: 'Could not save the settings',
      action: () async {
        final doc = await ref
            .read(apiProvider)
            .saveModuleSettings(widget.moduleId, values);
        if (mounted) _doc = doc;
      },
    );
    if (mounted) setState(() => _saving = false);
  }

  @override
  Widget build(BuildContext context) {
    final doc = _doc;
    if (_loading) {
      return const SettingsSectionCard(
        title: 'Settings',
        children: [
          Padding(
            padding: EdgeInsets.all(AppSpacing.s16),
            child: Center(child: AppSpinner(size: AppSpinnerSize.lg)),
          ),
        ],
      );
    }
    if (doc == null) {
      return SettingsSectionCard(
        title: 'Settings',
        children: [
          Padding(
            padding: const EdgeInsets.all(AppSpacing.s16),
            child: AppErrorState(
              message: _loadError ?? 'Could not load the settings',
              onRetry: _load,
            ),
          ),
        ],
      );
    }

    if (doc.settings.isEmpty) return const SizedBox.shrink();
    return ModuleSettingsForm(
      key: ValueKey(successTick),
      doc: doc,
      saving: _saving,
      error: actionError,

      onDismissError: clearActionError,
      onSave: _save,
    );
  }
}
