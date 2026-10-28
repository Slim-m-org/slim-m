// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Runs the requests that change one object strictly in the order they were made.
/// Two quick drags of the same note otherwise race, and the older one can land last on the server while this screen shows the newer.
library;

class ObjectOpChain {
  final Map<String, Future<void>> _tails = {};

  Future<T> run<T>(String objectId, Future<T> Function() task) {
    final previous = _tails[objectId] ?? Future<void>.value();
    final result = previous.then((_) => task());
    late final Future<void> tail;
    tail = result.then<void>((_) {}, onError: (Object _) {}).whenComplete(() {
      if (identical(_tails[objectId], tail)) _tails.remove(objectId);
    });
    _tails[objectId] = tail;
    return result;
  }
}
