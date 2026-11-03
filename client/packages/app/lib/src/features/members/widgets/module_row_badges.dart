// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Which module badges a member row considers drawing.
library;

import 'package:slimm_api/api.dart' as api;

/// More than this is noise; the row folds what does not fit into a "+N" chip.
const int moduleBadgeInlineMax = 4;

/// The badges worth drawing: non-empty, up to the cap.
List<api.ModuleBadge> visibleModuleBadges(List<api.ModuleBadge>? badges) =>
    badges
        ?.where((badge) => !badge.item.isEmpty)
        .take(moduleBadgeInlineMax)
        .toList(growable: false) ??
    const [];
