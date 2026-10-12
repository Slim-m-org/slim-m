// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Changing your own password, under Account & devices. Needs the current
/// password, and a current code while two-factor is on; signs the other
/// devices out and keeps this one.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../providers/providers.dart';
import 'change_password_sheet.dart';
import 'reauth_sheet.dart' show reauthFailure;
import 'settings_notice.dart';
import 'settings_section_header.dart';

class ChangePasswordSection extends ConsumerStatefulWidget {
  const ChangePasswordSection({super.key});

  @override
  ConsumerState<ChangePasswordSection> createState() =>
      _ChangePasswordSectionState();
}

class _ChangePasswordSectionState extends ConsumerState<ChangePasswordSection> {
  String? _loadError;
  bool _changed = false;

  Future<void> _open() async {
    final bool needsCode;
    try {
      needsCode = (await ref.read(apiProvider).totpStatus()).enabled;
    } on api.ApiException catch (e) {
      if (mounted) setState(() => _loadError = e.message);
      return;
    }
    if (!mounted) return;
    setState(() {
      _loadError = null;
      _changed = false;
    });
    final done = await showChangePasswordSheet(
      context,
      askForCode: needsCode,
      onSubmit: _submit,
    );
    if (done == true && mounted) setState(() => _changed = true);
  }

  Future<String?> _submit(String current, String next, String? code) async {
    try {
      await ref
          .read(apiProvider)
          .changePassword(
            currentPassword: current,
            newPassword: next,
            code: code,
          );
      return null;
    } on api.ApiException catch (e) {
      return reauthFailure(e);
    }
  }

  @override
  Widget build(BuildContext context) => SettingsSectionCard(
    title: 'Password',
    description: 'Changing it signs out your other devices.',
    children: [
      AppListRow(
        label: 'Change password',
        leading: const Icon(AppIcons.changePassword),
        onTap: _open,
      ),
      if (_changed) const SettingsNotice(message: 'Password changed.'),
      if (_loadError case final error?)
        Padding(
          padding: const EdgeInsets.all(AppSpacing.s8),
          child: AppErrorState(
            message: 'Could not start the change.',
            detail: error,
            onRetry: _open,
            onDismiss: () => setState(() => _loadError = null),
          ),
        ),
    ],
  );
}
