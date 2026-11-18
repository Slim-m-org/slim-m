// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The top of the sign-in form: what it is for, and where it is about to
/// connect. Split from `sign_in_screen.dart` for its size ceiling.
///
/// Every state names the destination: the identity chip once the server has
/// answered, a quieter line naming the host until then, and, for the
/// official Space whose address field is collapsed, why the server could not
/// be used, since there is no field for that to sit under.
library;

import 'package:flutter/material.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_design_system/design_system.dart';

import '../widgets/server_identity_chip.dart';

class SignInDestination extends StatelessWidget {
  const SignInDestination({
    super.key,
    required this.title,
    required this.host,
    required this.version,
    required this.status,
    this.error,
  });

  final String title;
  final String host;

  /// What the server said about itself, or null while it has not.
  final Version? version;
  final ServerIdentityStatus status;

  /// Why the server cannot be used, when no address field shows it.
  final String? error;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final error = this.error;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          title,
          style: AppText.title.copyWith(
            color: tokens.textPrimary,
            fontWeight: AppWeights.semi,
          ),
        ),
        const SizedBox(height: AppSpacing.s8),
        if (version case final version?)
          ServerIdentityChip(
            spaceName: version.displayName,
            host: host,
            status: status,
          )
        else
          Container(
            constraints: const BoxConstraints(
              minHeight: ServerIdentityChip.rowHeight,
            ),
            margin: const EdgeInsets.only(bottom: AppSpacing.s16),
            alignment: Alignment.centerLeft,
            child: Text(
              'Connecting to $host',
              style: ServerIdentityChip.hostStyle(tokens),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.s16),
            child: Semantics(
              liveRegion: true,
              child: Text(
                error,
                style: AppText.caption.copyWith(color: tokens.dangerText),
              ),
            ),
          ),
      ],
    );
  }
}
