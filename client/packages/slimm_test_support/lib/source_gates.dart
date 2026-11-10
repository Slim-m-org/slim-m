// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What a source-reading gate needs: the comment and string scrubber and the
/// repo root. A library of its own so a package's tests can use it without
/// pulling in the fake server and its HTTP dependencies.
library;

export 'src/code_only.dart';
export 'src/repo_root.dart';
