// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The non-web side of the conditional import; never reached off the web.
library;

Object? applyWebGain(String trackCid, double gain) =>
    UnsupportedError('Web Audio gain only exists in a browser');
