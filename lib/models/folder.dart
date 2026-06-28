/// A user-created folder that groups cards within the collection.
///
/// Each card may belong to at most one folder. Folders are purely an
/// organizational overlay; deleting a folder does not delete its cards (they
/// simply become unfiled).
class Folder {
  final int? id;
  final String name;

  const Folder({this.id, required this.name});

  Map<String, Object?> toMap() => {'id': id, 'name': name};

  factory Folder.fromMap(Map<String, Object?> map) =>
      Folder(id: map['id'] as int?, name: map['name'] as String);
}
