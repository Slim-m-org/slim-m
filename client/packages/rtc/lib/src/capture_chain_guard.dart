// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The browser capture chain's failure rules, free of browser types so a VM
/// test can drive them.
library;

/// When a failed chain may be tried again; the pause keeps a broken asset from being refetched on every mic open.
class ChainRetry {
  ChainRetry({this.pause = const Duration(seconds: 30)});

  final Duration pause;
  DateTime? _after;

  bool get failed => _after != null;

  void fail(DateTime now) => _after = now.add(pause);

  void clear() => _after = null;

  bool due(DateTime now) {
    final after = _after;
    return after != null && now.isAfter(after);
  }
}

/// Runs [attach], and gives back [raw] when it throws or does not finish within [timeout].
Future<T> attachOrRaw<T>({
  required Future<T> Function() attach,
  required T raw,
  required Duration timeout,
  required void Function(Object error, StackTrace stack) onFailed,
}) async {
  try {
    return await attach().timeout(timeout);
  } on Object catch (error, stack) {
    onFailed(error, stack);
    return raw;
  }
}

/// Whether a context that something plays through needs a resume.
bool contextNeedsResume(String state, {required bool inUse}) =>
    inUse && state != 'running' && state != 'closed';

/// The element is muted only while the context plays for it, or is about to.
bool elementShouldBeMuted(String state, {required bool resuming}) =>
    state == 'running' || resuming;
