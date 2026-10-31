// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Why a verified-download attempt stopped, in words the persistent error
/// state can show. Every failure leaves nothing staged (decision 0041).
library;

enum SelfUpdateFailureKind {
  unreachable,
  badSignature,
  badManifest,
  unsupportedSchema,
  insufficientSpace,
  downloadFailed,
  sizeMismatch,
  checksumMismatch,
  unsupportedInstall,
  installFailed,
  rolledBack,
  noArtifactForPlatform,
  launcherOutdated,
}

class SelfUpdateFailure implements Exception {
  const SelfUpdateFailure(
    this.kind,
    this.message, {
    this.detail,
    this.releaseUrl,
  });

  final SelfUpdateFailureKind kind;

  /// Plain words for `AppErrorState.message`; never a raw exception.
  final String message;

  /// Technical detail for `AppErrorState.detail`.
  final String? detail;

  /// The release page to download from by hand, when that is the way forward.
  final String? releaseUrl;

  @override
  String toString() => 'SelfUpdateFailure(${kind.name}): $message';
}
