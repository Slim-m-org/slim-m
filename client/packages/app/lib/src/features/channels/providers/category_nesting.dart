// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Whether this server files categories under one another (decision 0120).
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// True once a category listing carried `parent_id`. An older server never
/// does, and must not be asked for a sub-category it would make top-level.
final categoriesNestProvider = StateProvider<bool>((ref) => false);

/// The categories this account is listed only as a heading, from the last
/// listing: shown, but never offered to rename, move, delete or drag.
final headingOnlyCategoriesProvider = StateProvider<Set<String>>(
  (ref) => const {},
);
