import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../models/deck.dart';
import '../models/deck_card.dart';
import '../models/folder.dart';
import '../models/mtg_card.dart';
import 'card_backend.dart';

/// [CardBackend] backed by a local SQLite file via [sqflite_common_ffi]. Used
/// automatically when SQL Server isn't available, so the app works on any
/// machine with no server setup. The database lives in the app support
/// directory as `mtg_collection.db`.
class SqliteBackend implements CardBackend {
  Database? _db;
  Database get _database {
    final db = _db;
    if (db == null) {
      throw StateError('SqliteBackend.init() must be called before use.');
    }
    return db;
  }

  /// [path] overrides the database location (used in tests); defaults to
  /// `mtg_collection.db` in the app support directory.
  @override
  Future<void> init({String? path}) async {
    if (_db != null) return;
    sqfliteFfiInit();
    final dbPath = path ??
        p.join((await getApplicationSupportDirectory()).path,
            'mtg_collection.db');
    _db = await databaseFactoryFfi.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(
        // Bump `version` and add an `onUpgrade` branch below whenever the schema
        // changes, so existing local databases migrate forward in place.
        version: 5,
        onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
        onCreate: (db, version) async {
          await db.execute('''
            CREATE TABLE folders (
              id   INTEGER PRIMARY KEY AUTOINCREMENT,
              name TEXT NOT NULL
            )
          ''');
          await db.execute('''
            CREATE TABLE cards (
              id               INTEGER PRIMARY KEY AUTOINCREMENT,
              name             TEXT NOT NULL,
              set_code         TEXT NOT NULL,
              collector_number TEXT NOT NULL,
              foil             INTEGER NOT NULL DEFAULT 0,
              quantity         INTEGER NOT NULL DEFAULT 1,
              image_url        TEXT,
              price_usd        REAL,
              folder_id        INTEGER,
              colors           TEXT,
              color_identity   TEXT,
              tags             TEXT,
              type_line        TEXT,
              cmc              REAL,
              oracle_text      TEXT,
              FOREIGN KEY (folder_id) REFERENCES folders (id) ON DELETE SET NULL
            )
          ''');
          await _createDeckTables(db);
        },
        onUpgrade: (db, oldVersion, newVersion) async {
          // v2 added color identity and the deck tables.
          if (oldVersion < 2) {
            await db.execute('ALTER TABLE cards ADD COLUMN color_identity TEXT');
            await _createDeckTables(db);
          }
          // v3 added trade tags.
          if (oldVersion < 3) {
            await db.execute('ALTER TABLE cards ADD COLUMN tags TEXT');
          }
          // v4 added type line, mana value, and oracle text (advanced search).
          if (oldVersion < 4) {
            await db.execute('ALTER TABLE cards ADD COLUMN type_line TEXT');
            await db.execute('ALTER TABLE cards ADD COLUMN cmc REAL');
            await db.execute('ALTER TABLE cards ADD COLUMN oracle_text TEXT');
          }
          // v5 added oracle text on deck cards (deck analysis / advisor).
          if (oldVersion < 5) {
            await db
                .execute('ALTER TABLE deck_cards ADD COLUMN oracle_text TEXT');
          }
        },
      ),
    );
  }

  /// Creates the `decks` and `deck_cards` tables. Shared by [init]'s onCreate
  /// and the v1→v2 migration (decks were added in v2).
  Future<void> _createDeckTables(Database db) async {
    await db.execute('''
      CREATE TABLE decks (
        id     INTEGER PRIMARY KEY AUTOINCREMENT,
        name   TEXT NOT NULL,
        format TEXT
      )
    ''');
    await db.execute('''
      CREATE TABLE deck_cards (
        id               INTEGER PRIMARY KEY AUTOINCREMENT,
        deck_id          INTEGER NOT NULL,
        name             TEXT NOT NULL,
        set_code         TEXT NOT NULL,
        collector_number TEXT NOT NULL,
        foil             INTEGER NOT NULL DEFAULT 0,
        quantity         INTEGER NOT NULL DEFAULT 1,
        image_url        TEXT,
        price_usd        REAL,
        colors           TEXT,
        color_identity   TEXT,
        cmc              REAL,
        type_line        TEXT,
        oracle_text      TEXT,
        board            TEXT NOT NULL DEFAULT 'main',
        FOREIGN KEY (deck_id) REFERENCES decks (id) ON DELETE CASCADE
      )
    ''');
  }

  /// Closes the database (used in tests and on shutdown).
  Future<void> close() async {
    await _db?.close();
    _db = null;
  }

  /// Builds an insertable `cards` row from [c], omitting `id` so SQLite
  /// autoincrements it. Tags are JSON-encoded to fit a single text column.
  Map<String, Object?> _toRow(MtgCard c) => {
        'name': c.name,
        'set_code': c.setCode,
        'collector_number': c.collectorNumber,
        'foil': c.foil ? 1 : 0,
        'quantity': c.quantity,
        'image_url': c.imageUrl,
        'price_usd': c.priceUsd,
        'folder_id': c.folderId,
        'colors': c.colors,
        'color_identity': c.colorIdentity,
        'tags': MtgCard.encodeTags(c.tags),
        'type_line': c.typeLine,
        'cmc': c.cmc,
        'oracle_text': c.oracleText,
      };

  // ---- Cards ---------------------------------------------------------------

  @override
  Future<int> addCard(MtgCard card) =>
      _database.insert('cards', _toRow(card));

  @override
  Future<void> setCardColors(int id, String colors) async {
    await _database
        .update('cards', {'colors': colors}, where: 'id = ?', whereArgs: [id]);
  }

  @override
  Future<void> setCardColorIdentity(int id, String identity) async {
    await _database.update('cards', {'color_identity': identity},
        where: 'id = ?', whereArgs: [id]);
  }

  @override
  Future<void> setCardTags(int id, List<String> tags) async {
    await _database.update('cards', {'tags': MtgCard.encodeTags(tags)},
        where: 'id = ?', whereArgs: [id]);
  }

  @override
  Future<void> setCardPrice(int id, double price) async {
    await _database
        .update('cards', {'price_usd': price}, where: 'id = ?', whereArgs: [id]);
  }

  @override
  Future<void> setCardDetails(
    int id, {
    required String typeLine,
    required double? cmc,
    required String oracleText,
  }) async {
    await _database.update(
      'cards',
      {'type_line': typeLine, 'cmc': cmc, 'oracle_text': oracleText},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  @override
  Future<List<String>> distinctSetCodes() async {
    final rows = await _database.rawQuery(
      'SELECT DISTINCT set_code FROM cards ORDER BY set_code COLLATE NOCASE',
    );
    return rows.map((r) => r['set_code'] as String).toList();
  }

  @override
  Future<AddResult> addOrMergeCard(MtgCard card) async {
    final existing = await _matchEntry(
      card.setCode,
      card.collectorNumber,
      card.foil,
      card.folderId,
    );
    if (existing != null) {
      final total = (existing['quantity'] as int) + card.quantity;
      await _database.update('cards', {'quantity': total},
          where: 'id = ?', whereArgs: [existing['id']]);
      return AddResult(merged: true, quantity: total);
    }
    await addCard(card);
    return AddResult(merged: false, quantity: card.quantity);
  }

  @override
  Future<void> moveQuantityToFolder(
    MtgCard card,
    int qty,
    int? destFolderId,
  ) async {
    if (destFolderId == card.folderId) return;
    final moveQty = qty.clamp(1, card.quantity);
    // If the destination folder already holds this printing, we merge into it;
    // otherwise we either re-file the whole entry or split off a new one.
    final dest = await _matchEntry(
      card.setCode,
      card.collectorNumber,
      card.foil,
      destFolderId,
    );
    final hasDest = dest != null;

    if (moveQty >= card.quantity) {
      // Moving the entire stack.
      if (hasDest) {
        final total = (dest['quantity'] as int) + card.quantity;
        await _database.update('cards', {'quantity': total},
            where: 'id = ?', whereArgs: [dest['id']]);
        await deleteCard(card.id!);
      } else {
        await _database.update('cards', {'folder_id': destFolderId},
            where: 'id = ?', whereArgs: [card.id]);
      }
    } else {
      // Splitting: decrement the source and move only `moveQty` across.
      await _database.rawUpdate(
        'UPDATE cards SET quantity = quantity - ? WHERE id = ?',
        [moveQty, card.id],
      );
      if (hasDest) {
        final total = (dest['quantity'] as int) + moveQty;
        await _database.update('cards', {'quantity': total},
            where: 'id = ?', whereArgs: [dest['id']]);
      } else {
        await addCard(card.copyWith(folderId: destFolderId, quantity: moveQty));
      }
    }
  }

  /// Finds a matching entry (printing + foil + folder), or null.
  Future<Map<String, Object?>?> _matchEntry(
    String setCode,
    String collectorNumber,
    bool foil,
    int? folderId,
  ) async {
    final folderWhere =
        folderId == null ? 'folder_id IS NULL' : 'folder_id = ?';
    final args = <Object?>[
      setCode,
      collectorNumber,
      foil ? 1 : 0,
      if (folderId != null) folderId,
    ];
    final rows = await _database.query(
      'cards',
      columns: ['id', 'quantity'],
      where: 'set_code = ? AND collector_number = ? AND foil = ? AND $folderWhere',
      whereArgs: args,
      orderBy: 'id ASC',
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  @override
  Future<List<MtgCard>> getCards({
    String? query,
    int? folderId,
    CardSort sort = CardSort.name,
    bool ascending = true,
  }) async {
    final where = <String>[];
    final args = <Object?>[];

    if (query != null && query.trim().isNotEmpty) {
      final like = '%${query.trim()}%';
      where.add('(name LIKE ? OR set_code LIKE ? OR collector_number LIKE ?)');
      args..add(like)..add(like)..add(like);
    }
    if (folderId == unfiledSentinel) {
      where.add('folder_id IS NULL');
    } else if (folderId != null) {
      where.add('folder_id = ?');
      args.add(folderId);
    }

    final rows = await _database.query(
      'cards',
      where: where.isEmpty ? null : where.join(' AND '),
      whereArgs: args.isEmpty ? null : args,
      orderBy: _orderBy(sort, ascending),
    );
    return rows.map(_cardFromRow).toList();
  }

  /// Maps a [CardSort] to a SQL ORDER BY clause. Ties break on name; set/number
  /// sorting casts the collector number to an integer so "10" sorts after "9".
  String _orderBy(CardSort sort, bool ascending) {
    final dir = ascending ? 'ASC' : 'DESC';
    switch (sort) {
      case CardSort.name:
        return 'name COLLATE NOCASE $dir, set_code ASC';
      case CardSort.setNumber:
        return 'set_code $dir, CAST(collector_number AS INTEGER) $dir, '
            'collector_number $dir';
      case CardSort.price:
        return 'price_usd $dir, name ASC';
      case CardSort.quantity:
        return 'quantity $dir, name ASC';
      case CardSort.color:
        return '$_colorRankSql $dir, name ASC';
      case CardSort.dateAdded:
        return 'id $dir';
    }
  }

  /// SQL mirror of [MtgCard.colorRank]: W,U,B,R,G, then multicolor, then
  /// colorless, so color sorting matches the aggregated in-memory view.
  static const String _colorRankSql = '''
    CASE
      WHEN colors IS NULL OR colors = '' THEN 7
      WHEN length(colors) > 1 THEN 6
      WHEN colors = 'W' THEN 1
      WHEN colors = 'U' THEN 2
      WHEN colors = 'B' THEN 3
      WHEN colors = 'R' THEN 4
      WHEN colors = 'G' THEN 5
      ELSE 8
    END''';

  @override
  Future<void> updateCard(MtgCard card) async {
    // Note: colors is intentionally left untouched (preserved on edits).
    await _database.update(
      'cards',
      {
        'name': card.name,
        'set_code': card.setCode,
        'collector_number': card.collectorNumber,
        'foil': card.foil ? 1 : 0,
        'quantity': card.quantity,
        'image_url': card.imageUrl,
        'price_usd': card.priceUsd,
        'folder_id': card.folderId,
      },
      where: 'id = ?',
      whereArgs: [card.id],
    );
  }

  @override
  Future<void> deleteCard(int cardId) async {
    await _database.delete('cards', where: 'id = ?', whereArgs: [cardId]);
  }

  @override
  Future<void> deleteCards(List<int> cardIds) async {
    if (cardIds.isEmpty) return;
    final placeholders = List.filled(cardIds.length, '?').join(', ');
    await _database
        .delete('cards', where: 'id IN ($placeholders)', whereArgs: cardIds);
  }

  // ---- Folders -------------------------------------------------------------

  @override
  Future<int> addFolder(String name) =>
      _database.insert('folders', {'name': name});

  @override
  Future<int> getOrCreateFolder(String name) async {
    final rows = await _database.query('folders',
        columns: ['id'], where: 'name = ?', whereArgs: [name], limit: 1);
    if (rows.isNotEmpty) return rows.first['id'] as int;
    return addFolder(name);
  }

  @override
  Future<List<Folder>> getFolders() async {
    final rows =
        await _database.query('folders', orderBy: 'name COLLATE NOCASE ASC');
    return rows
        .map((r) => Folder(id: r['id'] as int?, name: r['name'] as String))
        .toList();
  }

  @override
  Future<void> renameFolder(int id, String name) async {
    await _database
        .update('folders', {'name': name}, where: 'id = ?', whereArgs: [id]);
  }

  @override
  Future<void> deleteFolder(int id) async {
    await _database.delete('folders', where: 'id = ?', whereArgs: [id]);
  }

  @override
  Future<Map<int, int>> folderCardCounts() async {
    final rows = await _database.rawQuery(
      'SELECT folder_id, COUNT(*) AS c FROM cards '
      'WHERE folder_id IS NOT NULL GROUP BY folder_id',
    );
    return {
      for (final r in rows) r['folder_id'] as int: r['c'] as int,
    };
  }

  // ---- Decks ---------------------------------------------------------------

  @override
  Future<int> addDeck(String name, String? format) =>
      _database.insert('decks', {'name': name, 'format': format});

  @override
  Future<List<Deck>> getDecks() async {
    final rows = await _database.query('decks', orderBy: 'name COLLATE NOCASE ASC');
    return rows
        .map((r) => Deck(
              id: r['id'] as int?,
              name: r['name'] as String,
              format: r['format'] as String?,
            ))
        .toList();
  }

  @override
  Future<void> renameDeck(int id, String name) async {
    await _database
        .update('decks', {'name': name}, where: 'id = ?', whereArgs: [id]);
  }

  @override
  Future<void> setDeckFormat(int id, String? format) async {
    await _database
        .update('decks', {'format': format}, where: 'id = ?', whereArgs: [id]);
  }

  @override
  Future<void> deleteDeck(int id) async {
    await _database.delete('decks', where: 'id = ?', whereArgs: [id]);
  }

  @override
  Future<Map<int, int>> deckCardCounts() async {
    final rows = await _database.rawQuery(
      'SELECT deck_id, SUM(quantity) AS c FROM deck_cards GROUP BY deck_id',
    );
    return {
      for (final r in rows) r['deck_id'] as int: (r['c'] as int?) ?? 0,
    };
  }

  // ---- Deck cards ----------------------------------------------------------

  @override
  Future<int> addOrMergeDeckCard(DeckCard card) async {
    // A card is "the same" within a deck when printing, foil, AND board match —
    // so the same card can exist independently on main vs. side.
    final existing = await _database.query(
      'deck_cards',
      columns: ['id', 'quantity'],
      where: 'deck_id = ? AND set_code = ? AND collector_number = ? '
          'AND foil = ? AND board = ?',
      whereArgs: [
        card.deckId,
        card.setCode,
        card.collectorNumber,
        card.foil ? 1 : 0,
        card.board,
      ],
      orderBy: 'id ASC',
      limit: 1,
    );
    if (existing.isNotEmpty) {
      final id = existing.first['id'] as int;
      final total = (existing.first['quantity'] as int) + card.quantity;
      await _database.update('deck_cards', {'quantity': total},
          where: 'id = ?', whereArgs: [id]);
      return id;
    }
    return _database.insert('deck_cards', _deckToRow(card));
  }

  @override
  Future<void> setDeckCardDetails(
    int id, {
    required String typeLine,
    required double cmc,
    required String colors,
    required String colorIdentity,
    required String oracleText,
  }) async {
    await _database.update(
      'deck_cards',
      {
        'type_line': typeLine,
        'cmc': cmc,
        'colors': colors,
        'color_identity': colorIdentity,
        'oracle_text': oracleText,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  @override
  Future<List<DeckCard>> getDeckCards(int deckId) async {
    final rows = await _database.query('deck_cards',
        where: 'deck_id = ?', whereArgs: [deckId], orderBy: 'name COLLATE NOCASE ASC');
    return rows.map(DeckCard.fromMap).toList();
  }

  @override
  Future<void> updateDeckCardQuantity(int id, int quantity) async {
    await _database.update('deck_cards', {'quantity': quantity},
        where: 'id = ?', whereArgs: [id]);
  }

  @override
  Future<void> setDeckCardBoard(int id, String board) async {
    await _database.update('deck_cards', {'board': board},
        where: 'id = ?', whereArgs: [id]);
  }

  @override
  Future<void> removeDeckCard(int id) async {
    await _database.delete('deck_cards', where: 'id = ?', whereArgs: [id]);
  }

  /// Insertable `deck_cards` row from [c] with `id` removed for autoincrement.
  Map<String, Object?> _deckToRow(DeckCard c) {
    final m = c.toMap();
    m.remove('id');
    return m;
  }

  /// Rebuilds an [MtgCard] from a `cards` result row.
  MtgCard _cardFromRow(Map<String, Object?> r) {
    return MtgCard(
      id: r['id'] as int?,
      name: r['name'] as String,
      setCode: r['set_code'] as String,
      collectorNumber: r['collector_number'] as String,
      foil: (r['foil'] as int? ?? 0) == 1,
      quantity: r['quantity'] as int? ?? 1,
      imageUrl: r['image_url'] as String?,
      priceUsd: (r['price_usd'] as num?)?.toDouble(),
      folderId: r['folder_id'] as int?,
      colors: r['colors'] as String? ?? '',
      colorIdentity: r['color_identity'] as String? ?? '',
      tags: MtgCard.decodeTags(r['tags']),
      typeLine: r['type_line'] as String? ?? '',
      cmc: (r['cmc'] as num?)?.toDouble(),
      oracleText: r['oracle_text'] as String? ?? '',
    );
  }
}
