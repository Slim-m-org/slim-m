// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A one-line reason a moderation control is missing or refused, so a
/// moderator who knows they hold a bit and still sees no row for it - or a
/// refusal with nothing more than a generic 403 - has something to read
/// rather than guessing between "no permission," "this is you," or
/// "something's broken." screen-review moderation.md's cross-cutting
/// section names this as one shared pattern, reused across the member
/// popover, the report card, and any future moderation surface, rather than
/// each site inventing its own wording; `ReportCard`'s own self-target
/// caption is its first caller.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

class ModerationUnavailableCaption extends StatelessWidget {
  const ModerationUnavailableCaption(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Text(
      text,
      style: AppText.caption.copyWith(color: tokens.textSecondary),
    );
  }
}
