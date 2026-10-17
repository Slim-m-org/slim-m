// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Unsaved pronouns and about text from Settings > Profile, so the preview
/// card can follow each keystroke before the blur save lands.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

typedef ProfileDraft = ({String? pronouns, String? about});

final profileDraftProvider = StateProvider<ProfileDraft>(
  (ref) => (pronouns: null, about: null),
);
