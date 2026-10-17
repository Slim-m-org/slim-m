// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The app-lock toggle, under Account & profile: whether opening slim-m
/// needs Face ID, a fingerprint, or the device passcode first.
///
/// Absent entirely off `supportsBiometricLock` (Linux desktop and the web,
/// where nothing answers a `local_auth` call) rather than shown and
/// disabled: a control that can never do anything is worse than no control.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart' show supportsBiometricLock;

import '../providers/app_lock_preference.dart';
import 'settings_section_header.dart';
import 'settings_detail_row.dart';

class AppLockSection extends ConsumerWidget {
  const AppLockSection({super.key, this.supported});

  /// Injectable for tests, which otherwise run on whatever host the suite
  /// itself is on (Linux in CI); the real build reads `supportsBiometricLock`.
  final bool? supported;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!(supported ?? supportsBiometricLock)) return const SizedBox.shrink();

    final enabled = ref.watch(appLockPreferenceProvider);
    return SettingsSectionCard(
      title: 'App lock',
      description: 'Locks slim-m on this device, separate from your password.',
      children: [
        SettingsDetailRow(
          title: 'Require Face ID or fingerprint',
          badge: const AppBadge(
            variant: AppBadgeVariant.tag,
            label: 'Phones only',
          ),
          detail: 'Uses your device passcode if biometrics fail.',
          trailing: AppToggle(
            value: enabled,
            semanticLabel: 'Require Face ID or a fingerprint to open slim-m',
            onChanged: (next) =>
                ref.read(appLockPreferenceProvider.notifier).set(next),
          ),
        ),
      ],
    );
  }
}
