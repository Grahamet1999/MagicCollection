import 'package:dart_odbc/dart_odbc.dart';

import '../models/deck.dart';
import '../models/deck_card.dart';
import '../models/folder.dart';
import '../models/mtg_card.dart';
import 'card_backend.dart';
import 'db_config.dart';

/// [CardBackend] backed by a local Microsoft SQL Server instance over ODBC.
///
/// Uses the [dart_odbc] package, which loads the system ODBC Driver Manager
/// (odbc32.dll on Windows) and connects through the installed
/// "ODBC Driver 18 for SQL Server". [init] throws [BackendUnavailableException]
/// when it can't connect, so the facade can fall back to SQLite.
///
/// Note on parameters: dart_odbc 6.2.0 binds parameters with a column size of
/// 0, which SQL Server's ODBC driver rejects for character types (HY104). We
/// therefore build statements with safely-escaped inline literals via [_lit].
class SqlServerBackend implements CardBackend {
  DartOdbc? _odbc;
  DartOdbc get _db {
    final db = _odbc;
    if (db == null) {
      throw StateError('SqlServerBackend.init() must be called before use.');
    }
    return db;
  }

  /// Connects to the local SQL Server, creating the app database if needed, then
  /// ensures the schema exists and is migrated. Throws
  /// [BackendUnavailableException] on any connection failure so the facade can
  /// fall back to SQLite.
  @override
  Future<void> init() async {
    if (_odbc != null) return;

    final DartOdbc odbc;
    try {
      odbc = DartOdbc();
      // Connect to `master` to ensure our database exists, then reconnect to it.
      await odbc.connectWithConnectionString(
        DbConfig.connectionString('master'),
      );
      await odbc.execute(
        "IF DB_ID('${DbConfig.database}') IS NULL "
        'CREATE DATABASE [${DbConfig.database}]',
      );
      await odbc.disconnect();
      await odbc.connectWithConnectionString(
        DbConfig.connectionString(DbConfig.database),
      );
    } catch (e) {
      throw BackendUnavailableException('SQL Server not available: $e');
    }

    await _createSchema(odbc);
    await _migrate(odbc);
    _odbc = odbc;
  }

  /// Adds columns introduced after the initial schema (colors, color identity,
  /// tags). Each guarded by COL_LENGTH so it's a no-op on already-migrated
  /// databases — this is the SQL Server counterpart to SQLite's onUpgrade.
  Future<void> _migrate(DartOdbc odbc) async {
    await odbc.execute(
      "IF COL_LENGTH('dbo.cards', 'colors') IS NULL "
      'ALTER TABLE dbo.cards ADD colors NVARCHAR(10) NULL',
    );
    await odbc.execute(
      "IF COL_LENGTH('dbo.cards', 'color_identity') IS NULL "
      'ALTER TABLE dbo.cards ADD color_identity NVARCHAR(10) NULL',
    );
    await odbc.execute(
      "IF COL_LENGTH('dbo.cards', 'tags') IS NULL "
      'ALTER TABLE dbo.cards ADD tags NVARCHAR(1000) NULL',
    );
    await odbc.execute(
      "IF COL_LENGTH('dbo.cards', 'type_line') IS NULL "
      'ALTER TABLE dbo.cards ADD type_line NVARCHAR(255) NULL',
    );
    await odbc.execute(
      "IF COL_LENGTH('dbo.cards', 'cmc') IS NULL "
      'ALTER TABLE dbo.cards ADD cmc DECIMAL(6,2) NULL',
    );
    await odbc.execute(
      "IF COL_LENGTH('dbo.cards', 'oracle_text') IS NULL "
      'ALTER TABLE dbo.cards ADD oracle_text NVARCHAR(MAX) NULL',
    );
    await odbc.execute(
      "IF COL_LENGTH('dbo.deck_cards', 'oracle_text') IS NULL "
      'ALTER TABLE dbo.deck_cards ADD oracle_text NVARCHAR(MAX) NULL',
    );
  }

  /// Creates the folders/cards/decks/deck_cards tables if they don't yet exist.
  /// Each CREATE is guarded by OBJECT_ID so re-running is safe. Mirrors the
  /// SQLite schema in [SqliteBackend].
  Future<void> _createSchema(DartOdbc odbc) async {
    await odbc.execute('''
      IF OBJECT_ID('dbo.folders', 'U') IS NULL
      CREATE TABLE dbo.folders (
        id   INT IDENTITY(1,1) PRIMARY KEY,
        name NVARCHAR(255) NOT NULL
      )
    ''');
    await odbc.execute('''
      IF OBJECT_ID('dbo.cards', 'U') IS NULL
      CREATE TABLE dbo.cards (
        id               INT IDENTITY(1,1) PRIMARY KEY,
        name             NVARCHAR(255) NOT NULL,
        set_code         NVARCHAR(50)  NOT NULL,
        collector_number NVARCHAR(50)  NOT NULL,
        foil             BIT NOT NULL DEFAULT 0,
        quantity         INT NOT NULL DEFAULT 1,
        image_url        NVARCHAR(1000),
        price_usd        DECIMAL(12,2),
        folder_id        INT NULL,
        colors           NVARCHAR(10) NULL,
        color_identity   NVARCHAR(10) NULL,
        tags             NVARCHAR(1000) NULL,
        type_line        NVARCHAR(255) NULL,
        cmc              DECIMAL(6,2) NULL,
        oracle_text      NVARCHAR(MAX) NULL,
        CONSTRAINT FK_cards_folder FOREIGN KEY (folder_id)
          REFERENCES dbo.folders (id) ON DELETE SET NULL
      )
    ''');
    await odbc.execute('''
      IF OBJECT_ID('dbo.decks', 'U') IS NULL
      CREATE TABLE dbo.decks (
        id     INT IDENTITY(1,1) PRIMARY KEY,
        name   NVARCHAR(255) NOT NULL,
        format NVARCHAR(50) NULL
      )
    ''');
    await odbc.execute('''
      IF OBJECT_ID('dbo.deck_cards', 'U') IS NULL
      CREATE TABLE dbo.deck_cards (
        id               INT IDENTITY(1,1) PRIMARY KEY,
        deck_id          INT NOT NULL,
        name             NVARCHAR(255) NOT NULL,
        set_code         NVARCHAR(50)  NOT NULL,
        collector_number NVARCHAR(50)  NOT NULL,
        foil             BIT NOT NULL DEFAULT 0,
        quantity         INT NOT NULL DEFAULT 1,
        image_url        NVARCHAR(1000),
        price_usd        DECIMAL(12,2),
        colors           NVARCHAR(10) NULL,
        color_identity   NVARCHAR(10) NULL,
        cmc              DECIMAL(6,2) NULL,
        type_line        NVARCHAR(255) NULL,
        oracle_text      NVARCHAR(MAX) NULL,
        board            NVARCHAR(20) NOT NULL DEFAULT 'main',
        CONSTRAINT FK_deck_cards_deck FOREIGN KEY (deck_id)
          REFERENCES dbo.decks (id) ON DELETE CASCADE
      )
    ''');
  }

  // ---- Cards ---------------------------------------------------------------

  @override
  Future<int> addCard(MtgCard card) async {
    final rows = await _db.execute(
      'INSERT INTO dbo.cards '
      '(name, set_code, collector_number, foil, quantity, image_url, price_usd, folder_id, colors, color_identity, tags, type_line, cmc, oracle_text) '
      'OUTPUT INSERTED.id AS id VALUES ('
      '${_lit(card.name)}, ${_lit(card.setCode)}, ${_lit(card.collectorNumber)}, '
      '${_lit(card.foil)}, ${_lit(card.quantity)}, ${_lit(card.imageUrl)}, '
      '${_lit(card.priceUsd)}, ${_lit(card.folderId)}, ${_lit(card.colors)}, '
      '${_lit(card.colorIdentity)}, ${_lit(MtgCard.encodeTags(card.tags))}, '
      '${_lit(card.typeLine)}, ${_lit(card.cmc)}, ${_lit(card.oracleText)})',
    );
    return _asInt(rows.isNotEmpty ? rows.first['id'] : null) ?? -1;
  }

  @override
  Future<void> setCardColors(int id, String colors) async {
    await _db.execute(
      'UPDATE dbo.cards SET colors = ${_lit(colors)} WHERE id = ${_lit(id)}',
    );
  }

  @override
  Future<void> setCardTags(int id, List<String> tags) async {
    await _db.execute(
      'UPDATE dbo.cards SET tags = ${_lit(MtgCard.encodeTags(tags))} '
      'WHERE id = ${_lit(id)}',
    );
  }

  @override
  Future<void> setCardColorIdentity(int id, String identity) async {
    await _db.execute(
      'UPDATE dbo.cards SET color_identity = ${_lit(identity)} '
      'WHERE id = ${_lit(id)}',
    );
  }

  @override
  Future<void> setCardPrice(int id, double price) async {
    await _db.execute(
      'UPDATE dbo.cards SET price_usd = ${_lit(price)} WHERE id = ${_lit(id)}',
    );
  }

  @override
  Future<void> setCardDetails(
    int id, {
    required String typeLine,
    required double? cmc,
    required String oracleText,
  }) async {
    await _db.execute(
      'UPDATE dbo.cards SET type_line = ${_lit(typeLine)}, '
      'cmc = ${_lit(cmc)}, oracle_text = ${_lit(oracleText)} '
      'WHERE id = ${_lit(id)}',
    );
  }

  @override
  Future<List<String>> distinctSetCodes() async {
    final rows = await _db.execute(
      'SELECT DISTINCT set_code FROM dbo.cards ORDER BY set_code',
    );
    return rows.map((r) => r['set_code'] as String).toList();
  }

  @override
  Future<AddResult> addOrMergeCard(MtgCard card) async {
    final existing = await _db.execute(
      'SELECT TOP 1 id, quantity FROM dbo.cards '
      'WHERE set_code = ${_lit(card.setCode)} '
      'AND collector_number = ${_lit(card.collectorNumber)} '
      'AND foil = ${_lit(card.foil)} '
      'AND ${_folderCondition(card.folderId)} '
      'ORDER BY id ASC',
    );
    if (existing.isNotEmpty) {
      final id = _asInt(existing.first['id'])!;
      final total = (_asInt(existing.first['quantity']) ?? 0) + card.quantity;
      await _db.execute(
        'UPDATE dbo.cards SET quantity = ${_lit(total)} WHERE id = ${_lit(id)}',
      );
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
    if (destFolderId == card.folderId) return; // already there
    final moveQty = qty.clamp(1, card.quantity);

    final dest = await _db.execute(
      'SELECT TOP 1 id, quantity FROM dbo.cards '
      'WHERE set_code = ${_lit(card.setCode)} '
      'AND collector_number = ${_lit(card.collectorNumber)} '
      'AND foil = ${_lit(card.foil)} '
      'AND ${_folderCondition(destFolderId)} '
      'ORDER BY id ASC',
    );
    final hasDest = dest.isNotEmpty;

    if (moveQty >= card.quantity) {
      if (hasDest) {
        final destId = _asInt(dest.first['id'])!;
        final total = (_asInt(dest.first['quantity']) ?? 0) + card.quantity;
        await _db.execute(
          'UPDATE dbo.cards SET quantity = ${_lit(total)} WHERE id = ${_lit(destId)}',
        );
        await deleteCard(card.id!);
      } else {
        await _moveCardToFolder(card.id!, destFolderId);
      }
    } else {
      await _db.execute(
        'UPDATE dbo.cards SET quantity = quantity - ${_lit(moveQty)} '
        'WHERE id = ${_lit(card.id)}',
      );
      if (hasDest) {
        final destId = _asInt(dest.first['id'])!;
        final total = (_asInt(dest.first['quantity']) ?? 0) + moveQty;
        await _db.execute(
          'UPDATE dbo.cards SET quantity = ${_lit(total)} WHERE id = ${_lit(destId)}',
        );
      } else {
        await addCard(card.copyWith(folderId: destFolderId, quantity: moveQty));
      }
    }
  }

  /// Re-files a card into [folderId] (null = unfiled) without touching quantity.
  Future<void> _moveCardToFolder(int cardId, int? folderId) async {
    await _db.execute(
      'UPDATE dbo.cards SET folder_id = ${_lit(folderId)} '
      'WHERE id = ${_lit(cardId)}',
    );
  }

  /// SQL predicate matching a given folder, using `IS NULL` for the unfiled case
  /// (since `folder_id = NULL` never matches in SQL).
  static String _folderCondition(int? folderId) =>
      folderId == null ? 'folder_id IS NULL' : 'folder_id = ${_lit(folderId)}';

  @override
  Future<List<MtgCard>> getCards({
    String? query,
    int? folderId,
    CardSort sort = CardSort.name,
    bool ascending = true,
  }) async {
    final where = <String>[];

    if (query != null && query.trim().isNotEmpty) {
      final like = _lit('%${query.trim()}%');
      where.add(
        '(name LIKE $like OR set_code LIKE $like OR collector_number LIKE $like)',
      );
    }

    if (folderId == unfiledSentinel) {
      where.add('folder_id IS NULL');
    } else if (folderId != null) {
      where.add('folder_id = ${_lit(folderId)}');
    }

    final clause = where.isEmpty ? '' : 'WHERE ${where.join(' AND ')}';
    final rows = await _db.execute(
      'SELECT id, name, set_code, collector_number, '
      'CAST(foil AS INT) AS foil, quantity, '
      'image_url, price_usd, folder_id, colors, color_identity, tags, '
      'type_line, cmc, oracle_text '
      'FROM dbo.cards $clause ORDER BY ${_orderBy(sort, ascending)}',
    );
    return rows.map(_cardFromRow).toList();
  }

  /// Maps a [CardSort] to a SQL ORDER BY clause. `TRY_CONVERT(INT, ...)` sorts
  /// numeric collector numbers correctly while tolerating non-numeric ones.
  String _orderBy(CardSort sort, bool ascending) {
    final dir = ascending ? 'ASC' : 'DESC';
    switch (sort) {
      case CardSort.name:
        return 'name $dir, set_code ASC';
      case CardSort.setNumber:
        return 'set_code $dir, TRY_CONVERT(INT, collector_number) $dir, '
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
      WHEN LEN(colors) > 1 THEN 6
      WHEN colors = 'W' THEN 1
      WHEN colors = 'U' THEN 2
      WHEN colors = 'B' THEN 3
      WHEN colors = 'R' THEN 4
      WHEN colors = 'G' THEN 5
      ELSE 8
    END''';

  @override
  Future<void> updateCard(MtgCard card) async {
    await _db.execute(
      'UPDATE dbo.cards SET '
      'name = ${_lit(card.name)}, set_code = ${_lit(card.setCode)}, '
      'collector_number = ${_lit(card.collectorNumber)}, foil = ${_lit(card.foil)}, '
      'quantity = ${_lit(card.quantity)}, image_url = ${_lit(card.imageUrl)}, '
      'price_usd = ${_lit(card.priceUsd)}, folder_id = ${_lit(card.folderId)} '
      'WHERE id = ${_lit(card.id)}',
    );
  }

  @override
  Future<void> deleteCard(int cardId) async {
    await _db.execute('DELETE FROM dbo.cards WHERE id = ${_lit(cardId)}');
  }

  @override
  Future<void> deleteCards(List<int> cardIds) async {
    if (cardIds.isEmpty) return;
    final inList = cardIds.map(_lit).join(', ');
    await _db.execute('DELETE FROM dbo.cards WHERE id IN ($inList)');
  }

  // ---- Folders -------------------------------------------------------------

  @override
  Future<int> addFolder(String name) async {
    final rows = await _db.execute(
      'INSERT INTO dbo.folders (name) OUTPUT INSERTED.id AS id '
      'VALUES (${_lit(name)})',
    );
    return _asInt(rows.isNotEmpty ? rows.first['id'] : null) ?? -1;
  }

  @override
  Future<int> getOrCreateFolder(String name) async {
    final rows = await _db.execute(
      'SELECT id FROM dbo.folders WHERE name = ${_lit(name)}',
    );
    if (rows.isNotEmpty) return _asInt(rows.first['id'])!;
    return addFolder(name);
  }

  @override
  Future<List<Folder>> getFolders() async {
    final rows = await _db.execute(
      'SELECT id, name FROM dbo.folders ORDER BY name ASC',
    );
    return rows
        .map((r) => Folder(id: _asInt(r['id']), name: r['name'] as String))
        .toList();
  }

  @override
  Future<void> renameFolder(int id, String name) async {
    await _db.execute(
      'UPDATE dbo.folders SET name = ${_lit(name)} WHERE id = ${_lit(id)}',
    );
  }

  @override
  Future<void> deleteFolder(int id) async {
    await _db.execute('DELETE FROM dbo.folders WHERE id = ${_lit(id)}');
  }

  @override
  Future<Map<int, int>> folderCardCounts() async {
    final rows = await _db.execute(
      'SELECT folder_id, COUNT(*) AS c FROM dbo.cards '
      'WHERE folder_id IS NOT NULL GROUP BY folder_id',
    );
    return {
      for (final r in rows) _asInt(r['folder_id'])!: _asInt(r['c']) ?? 0,
    };
  }

  // ---- Decks ---------------------------------------------------------------

  @override
  Future<int> addDeck(String name, String? format) async {
    final rows = await _db.execute(
      'INSERT INTO dbo.decks (name, format) OUTPUT INSERTED.id AS id '
      'VALUES (${_lit(name)}, ${_lit(format)})',
    );
    return _asInt(rows.isNotEmpty ? rows.first['id'] : null) ?? -1;
  }

  @override
  Future<List<Deck>> getDecks() async {
    final rows = await _db.execute(
      'SELECT id, name, format FROM dbo.decks ORDER BY name ASC',
    );
    return rows
        .map((r) => Deck(
              id: _asInt(r['id']),
              name: r['name'] as String,
              format: r['format'] as String?,
            ))
        .toList();
  }

  @override
  Future<void> renameDeck(int id, String name) async {
    await _db.execute(
      'UPDATE dbo.decks SET name = ${_lit(name)} WHERE id = ${_lit(id)}',
    );
  }

  @override
  Future<void> setDeckFormat(int id, String? format) async {
    await _db.execute(
      'UPDATE dbo.decks SET format = ${_lit(format)} WHERE id = ${_lit(id)}',
    );
  }

  @override
  Future<void> deleteDeck(int id) async {
    await _db.execute('DELETE FROM dbo.decks WHERE id = ${_lit(id)}');
  }

  @override
  Future<Map<int, int>> deckCardCounts() async {
    final rows = await _db.execute(
      'SELECT deck_id, SUM(quantity) AS c FROM dbo.deck_cards '
      'GROUP BY deck_id',
    );
    return {
      for (final r in rows) _asInt(r['deck_id'])!: _asInt(r['c']) ?? 0,
    };
  }

  // ---- Deck cards ----------------------------------------------------------

  @override
  Future<int> addOrMergeDeckCard(DeckCard card) async {
    final existing = await _db.execute(
      'SELECT TOP 1 id, quantity FROM dbo.deck_cards '
      'WHERE deck_id = ${_lit(card.deckId)} '
      'AND set_code = ${_lit(card.setCode)} '
      'AND collector_number = ${_lit(card.collectorNumber)} '
      'AND foil = ${_lit(card.foil)} '
      'AND board = ${_lit(card.board)} '
      'ORDER BY id ASC',
    );
    if (existing.isNotEmpty) {
      final id = _asInt(existing.first['id'])!;
      final total = (_asInt(existing.first['quantity']) ?? 0) + card.quantity;
      await _db.execute(
        'UPDATE dbo.deck_cards SET quantity = ${_lit(total)} '
        'WHERE id = ${_lit(id)}',
      );
      return id;
    }
    final rows = await _db.execute(
      'INSERT INTO dbo.deck_cards '
      '(deck_id, name, set_code, collector_number, foil, quantity, image_url, '
      'price_usd, colors, color_identity, cmc, type_line, oracle_text, board) '
      'OUTPUT INSERTED.id AS id VALUES ('
      '${_lit(card.deckId)}, ${_lit(card.name)}, ${_lit(card.setCode)}, '
      '${_lit(card.collectorNumber)}, ${_lit(card.foil)}, ${_lit(card.quantity)}, '
      '${_lit(card.imageUrl)}, ${_lit(card.priceUsd)}, ${_lit(card.colors)}, '
      '${_lit(card.colorIdentity)}, ${_lit(card.cmc)}, ${_lit(card.typeLine)}, '
      '${_lit(card.oracleText)}, ${_lit(card.board)})',
    );
    return _asInt(rows.isNotEmpty ? rows.first['id'] : null) ?? -1;
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
    await _db.execute(
      'UPDATE dbo.deck_cards SET type_line = ${_lit(typeLine)}, '
      'cmc = ${_lit(cmc)}, colors = ${_lit(colors)}, '
      'color_identity = ${_lit(colorIdentity)}, '
      'oracle_text = ${_lit(oracleText)} WHERE id = ${_lit(id)}',
    );
  }

  @override
  Future<List<DeckCard>> getDeckCards(int deckId) async {
    final rows = await _db.execute(
      'SELECT id, deck_id, name, set_code, collector_number, '
      'CAST(foil AS INT) AS foil, quantity, image_url, price_usd, colors, '
      'color_identity, cmc, type_line, oracle_text, board '
      'FROM dbo.deck_cards WHERE deck_id = ${_lit(deckId)} '
      'ORDER BY name ASC',
    );
    return rows.map(_deckCardFromRow).toList();
  }

  @override
  Future<void> updateDeckCardQuantity(int id, int quantity) async {
    await _db.execute(
      'UPDATE dbo.deck_cards SET quantity = ${_lit(quantity)} '
      'WHERE id = ${_lit(id)}',
    );
  }

  @override
  Future<void> setDeckCardBoard(int id, String board) async {
    await _db.execute(
      'UPDATE dbo.deck_cards SET board = ${_lit(board)} WHERE id = ${_lit(id)}',
    );
  }

  @override
  Future<void> removeDeckCard(int id) async {
    await _db.execute('DELETE FROM dbo.deck_cards WHERE id = ${_lit(id)}');
  }

  // ---- Helpers -------------------------------------------------------------

  /// Renders [value] as a safe inline SQL literal (see the class doc for why
  /// parameters aren't used). Strings are single-quoted with embedded quotes
  /// doubled to prevent SQL injection, and prefixed `N` for Unicode; bools
  /// become 1/0; null becomes NULL.
  static String _lit(Object? value) {
    if (value == null) return 'NULL';
    if (value is bool) return value ? '1' : '0';
    if (value is int) return value.toString();
    if (value is double) return value.toString();
    final escaped = value.toString().replaceAll("'", "''");
    return "N'$escaped'";
  }

  /// Rebuilds an [MtgCard] from a result row, coercing ODBC's loosely-typed
  /// values via the `_as*` helpers.
  MtgCard _cardFromRow(Map<String, dynamic> r) {
    return MtgCard(
      id: _asInt(r['id']),
      name: r['name'] as String,
      setCode: r['set_code'] as String,
      collectorNumber: r['collector_number'] as String,
      foil: _asBool(r['foil']),
      quantity: _asInt(r['quantity']) ?? 1,
      imageUrl: r['image_url'] as String?,
      priceUsd: _asDouble(r['price_usd']),
      folderId: _asInt(r['folder_id']),
      colors: r['colors'] as String? ?? '',
      colorIdentity: r['color_identity'] as String? ?? '',
      tags: MtgCard.decodeTags(r['tags']),
      typeLine: r['type_line'] as String? ?? '',
      cmc: _asDouble(r['cmc']),
      oracleText: r['oracle_text'] as String? ?? '',
    );
  }

  /// Rebuilds a [DeckCard] from a result row.
  DeckCard _deckCardFromRow(Map<String, dynamic> r) {
    return DeckCard(
      id: _asInt(r['id']),
      deckId: _asInt(r['deck_id'])!,
      name: r['name'] as String,
      setCode: r['set_code'] as String,
      collectorNumber: r['collector_number'] as String,
      foil: _asBool(r['foil']),
      quantity: _asInt(r['quantity']) ?? 1,
      imageUrl: r['image_url'] as String?,
      priceUsd: _asDouble(r['price_usd']),
      colors: r['colors'] as String? ?? '',
      colorIdentity: r['color_identity'] as String? ?? '',
      cmc: _asDouble(r['cmc']) ?? 0,
      typeLine: r['type_line'] as String? ?? '',
      oracleText: r['oracle_text'] as String? ?? '',
      board: r['board'] as String? ?? DeckBoard.main,
    );
  }

  // The ODBC layer can return numbers as int, num, or string depending on the
  // column type, so these helpers coerce defensively.

  /// Coerces an ODBC value to int?, parsing strings when needed.
  static int? _asInt(Object? v) {
    if (v == null) return null;
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v.toString());
  }

  /// Coerces an ODBC value to double?, parsing strings when needed.
  static double? _asDouble(Object? v) {
    if (v == null) return null;
    if (v is double) return v;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString());
  }

  /// Coerces an ODBC value to bool, treating 1/"1"/"true" as true. SQL Server's
  /// BIT columns are selected as INT (see [getCards]), so this handles both.
  static bool _asBool(Object? v) {
    if (v is bool) return v;
    if (v is num) return v != 0;
    final s = v?.toString().toLowerCase();
    return s == '1' || s == 'true';
  }
}
