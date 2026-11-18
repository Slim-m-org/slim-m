// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'package:flutter/widgets.dart';
import 'package:slimm_design_system/design_system.dart';

/// A failed load shown inline in a card or pane: the message and a retry, padded to the card rhythm.
class LoadErrorBlock extends StatelessWidget {
  const LoadErrorBlock({super.key, required this.message, this.onRetry});

  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(AppSpacing.s16),
    child: AppLoadRetry(
      onRetry: onRetry,
      child: AppErrorState(message: message, onRetry: onRetry),
    ),
  );
}
