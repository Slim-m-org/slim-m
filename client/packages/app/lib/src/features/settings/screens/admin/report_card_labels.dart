// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Naming who is who on a report card: the reported author or user (the
/// subject of the report) versus the reporter (its provenance). Split out of
/// `report_card.dart` to keep that file under budget.
///
/// Each resolves through `batchProfilesControllerProvider` rather than
/// rendering the raw id the wire carries, and each is labelled explicitly by
/// [ReportLabeledValue] rather than left to font weight and position to say
/// which is which - that read as a byline, exactly backwards from who
/// reported whom.
library;

import 'package:flutter/material.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

/// A label above a value, so a card names what it is showing rather than
/// leaning on position and weight to disambiguate it.
class ReportLabeledValue extends StatelessWidget {
  const ReportLabeledValue({
    super.key,
    required this.label,
    required this.value,
  });

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: AppText.caption.copyWith(
            color: tokens.textSecondary,
            fontWeight: AppWeights.medium,
          ),
        ),
        Text(
          value,
          style: AppText.body.copyWith(
            fontWeight: AppWeights.semi,
            color: tokens.textPrimary,
          ),
        ),
      ],
    );
  }
}

/// The reporter's name for the "Reporter" line. [id] itself null (the
/// server already anonymized that account) and a batch fetch that came back
/// without it (deleted since) read the same honest way; an id not yet asked
/// for reads as still loading, the same "Loading..." wording [subjectHeadline]
/// and [authorHeadline] use for the identical not-yet-fetched state, so a
/// card does not describe one unresolved id two different ways.
String reporterLabel(String? id, Map<String, api.UserProfile?> profiles) {
  if (id == null) return 'a deleted account';
  if (!profiles.containsKey(id)) return 'Loading...';
  return profiles[id]?.displayName ?? 'a deleted account';
}

/// The reported user's name for a user report's headline: the same three
/// states as [reporterLabel], worded to stand alone rather than complete a
/// sentence.
///
/// "Loading...", never "Resolving...": a headline sitting directly above an
/// `AppButton(label: 'Resolve')` and a "Resolve this report?" dialog cannot
/// share that verb, or a moderator reads it as the report already being
/// resolved.
String subjectHeadline(String id, Map<String, api.UserProfile?> profiles) {
  if (!profiles.containsKey(id)) return 'Loading...';
  return profiles[id]?.displayName ?? 'Deleted account';
}

/// Who wrote the reported message, for the headline of a message report.
///
/// A null id is not a lookup that failed: the server sends none when the
/// message has been hard-deleted or its author anonymized, and saying so is
/// more use to a moderator than a name that would be wrong. See
/// [subjectHeadline] for why the not-yet-fetched case says "Loading..."
/// rather than "Resolving...".
String authorHeadline(String? id, Map<String, api.UserProfile?> profiles) {
  if (id == null) return 'Author no longer on this Space';
  if (!profiles.containsKey(id)) return 'Loading...';
  return profiles[id]?.displayName ?? 'Deleted account';
}
