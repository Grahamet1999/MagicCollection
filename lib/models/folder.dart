/// A user-created folder that groups cards within the collection.
///
/// Each card may belong to at most one folder. Folders are purely an
/// organizational overlay; deleting a folder does not delete its cards (they
/// simply become unfiled).
class Folder {
  /// SQLite primary key. Null until the row has been inserted (the database
  /// assigns the id on insert).
  final int? id;

  /// User-visible folder name.
  final String name;

  const Folder({this.id, required this.name});

  /// Serializes to a row map for the `folders` table. Column names must match
  /// the schema in the database backends.
  Map<String, Object?> toMap() => {'id': id, 'name': name};

  /// Rebuilds a [Folder] from a `folders` table row.
  factory Folder.fromMap(Map<String, Object?> map) =>
      Folder(id: map['id'] as int?, name: map['name'] as String);
}
