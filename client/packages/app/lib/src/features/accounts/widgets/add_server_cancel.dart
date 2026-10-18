// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Backs out of "Add a server", back to the server that was on screen.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../providers/account_providers.dart';

/// Nothing unless the join flow was opened from the switcher.
class AddServerCancel extends ConsumerWidget {
  const AddServerCancel({super.key, this.disabled = false});

  final bool disabled;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(accountsSnapshotProvider.select((s) => s.canCancelAdd))) {
      return const SizedBox.shrink();
    }
    return AppButton(
      label: 'Cancel',
      variant: AppButtonVariant.ghost,
      disabled: disabled,
      onPressed: () => unawaited(ref.read(accountHostProvider)?.cancelAdd()),
    );
  }
}
