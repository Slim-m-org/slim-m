// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The rows and answers `FuzzServer` keeps, split from it for the file budget.
library;

class FuzzObject {
  FuzzObject({
    required this.id,
    required this.kind,
    required this.x,
    required this.y,
    required this.w,
    required this.h,
    required this.z,
    required this.seq,
    required this.author,
    required this.props,
  });

  final String id;
  final String kind;
  double x;
  double y;
  double w;
  double h;
  int z;
  final int seq;
  final String? author;
  Map<String, dynamic> props;
  int? deletedAt;

  bool get live => deletedAt == null;

  Map<String, dynamic> toJson() => {
    'id': id,
    'kind': kind,
    'z_index': z,
    'x': x,
    'y': y,
    'w': w,
    'h': h,
    'props': props,
    'author_id': author,
    'seq': seq,
    'created_at': 0,
  };
}

class FuzzOp {
  FuzzOp({
    required this.seq,
    required this.id,
    required this.kind,
    required this.actor,
    required this.createdAt,
  });

  final int seq;
  final String id;
  final String kind;
  final String actor;
  final int createdAt;
  String? objectId;
  List<String> targets = const [];
  double? x;
  double? y;
  double? w;
  double? h;
  int? beforeSeq;
  List<String> kinds = const [];
  String? scopeAuthor;
  String? targetOp;
  int? z;
  Map<String, dynamic>? props;
}

/// A refusal the HTTP layer would turn into a status code.
class FuzzRefusal implements Exception {
  const FuzzRefusal(this.status, this.message);

  final int status;
  final String message;
}

class FuzzSubmit {
  FuzzSubmit(this.op, this.affected, this.fresh);

  final FuzzOp? op;
  final int affected;
  final bool fresh;
  int seq = 0;
  String kind = '';
  String id = '';
  int createdAt = 0;
}
