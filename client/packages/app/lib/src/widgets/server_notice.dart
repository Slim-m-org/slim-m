// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The quiet lines the sign-in screen shows about the server in the field.
library;

import 'package:flutter/material.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_design_system/design_system.dart';

/// One fact about the server being joined: an icon, a sentence, and a live
/// region so a screen reader hears it when a probe makes it appear.
///
/// Never a blocker. Everything said here is something an operator may have
/// chosen on purpose, so the job is to inform the person joining, not to
/// decide for them.
class ServerNotice extends StatelessWidget {
  const ServerNotice({super.key, required this.icon, required this.message});

  final IconData icon;
  final String message;

  /// Carries its own gap from whatever sits above it, so a notice that has
  /// nothing to say can render as nothing without leaving a hole behind.
  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Semantics(
      liveRegion: true,
      child: Padding(
        padding: const EdgeInsets.only(top: AppSpacing.s8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: AppSizes.icon16, color: tokens.textSecondary),
            const SizedBox(width: AppSpacing.s8),
            Expanded(
              child: Text(
                message,
                style: AppText.caption.copyWith(color: tokens.textSecondary),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A fact about a server worth stopping on before an account is created there.
class ServerWarning {
  const ServerWarning(this.icon, this.message);

  final IconData icon;
  final String message;
}

/// What a server's missing safety tools cost whoever joins it, or null when it
/// offers both.
///
/// slim-m has no automated scanning and no authority above the deployment, so
/// reporting and blocking are the whole of a member's recourse. Says "could
/// not tell" rather than "has neither" for a server too old to advertise
/// anything.
ServerWarning? safetyWarning(Version version) => switch (version.safetyTools) {
  SafetyTools.present => null,
  SafetyTools.unknown => const ServerWarning(
    AppIcons.unknown,
    'This server is too old to say whether it offers reporting and blocking.',
  ),
  SafetyTools.missing => ServerWarning(
    AppIcons.shieldOff,
    _missingMessage(version.missingSafetyTools),
  ),
};

/// Names what is absent and what its absence costs, in that order: a list of
/// missing feature names tells someone nothing on its own.
String _missingMessage(List<String> missing) {
  final lacks = switch (missing) {
    ['report', 'block'] => 'report a message or block anyone',
    ['report'] => 'report a message or a person to whoever runs it',
    ['block'] => 'block anyone',
    _ => 'use its safety tools',
  };
  return 'This server offers no way to $lacks, but you can still join.';
}
