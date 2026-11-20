// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What this account may do with a cached category, read with the server's default.
library;

import 'database.dart';

/// A row a listing has not described yet counts as allowed, as an older server's would.
extension CategoryReach on ChannelCategoryRow {
  /// Whether this account may rename, move or delete it.
  bool get canManage => manageable ?? true;

  /// Whether this account may file a channel or sub-category under it.
  bool get canFile => fileable ?? true;
}
