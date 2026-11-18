// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// How many seeds a fuzz test explores: a quick sample by default, the full range when `SLIMM_FULL_FUZZ=1`.
/// CI sets it on pushes to main, so every commit a release is cut from runs the full range; findings are pinned in their own tests.
library;

import 'dart:io';

/// Whether this run explores the full seed range.
bool get fullFuzz => Platform.environment['SLIMM_FULL_FUZZ'] == '1';

/// [full] seeds when [fullFuzz], otherwise [quick].
int fuzzSeeds({required int full, required int quick}) =>
    fullFuzz ? full : quick;
