import 'package:dart_odbc/dart_odbc.dart';

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

  Future<void> _migrate(DartOdbc odbc) async {
    await odbc.execute(
      "IF COL_LENGTH('dbo.cards', 'colors') IS NULL "
      'ALTER TABLE dbo.cards ADD colors NVARCHAR(10) NULL',
    );
  }

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
        CONSTRAINT FK_cards_folder FOREIGN KEY (folder_id)
          REFERENCES dbo.folders (id) ON DELETE SET NULL
      )
    ''');
  }

  // ---- Cards ---------------------------------------------------------------

  @override
  Future<int> addCard(MtgCard card) async {
    final rows = await _db.execute(
      'INSERT INTO dbo.cards '
      '(name, set_code, collector_number, foil, quantity, image_url, price_usd, folder_id, colors) '
      'OUTPUT INSERTED.id AS id VALUES ('
      '${_lit(card.name)}, ${_lit(card.setCode)}, ${_lit(card.collectorNumber)}, '
      '${_lit(card.foil)}, ${_lit(card.quantity)}, ${_lit(card.imageUrl)}, '
      '${_lit(card.priceUsd)}, ${_lit(card.folderId)}, ${_lit(card.colors)})',
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
  Future<void> setCardPrice(int id, double price) async {
    await _db.execute(
      'UPDATE dbo.cards SET price_usd = ${_lit(price)} WHERE id = ${_lit(id)}',
    );
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

  Future<void> _moveCardToFolder(int cardId, int? folderId) async {
    await _db.execute(
      'UPDATE dbo.cards SET folder_id = ${_lit(folderId)} '
      'WHERE id = ${_lit(cardId)}',
    );
  }

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
      'image_url, price_usd, folder_id, colors '
      'FROM dbo.cards $clause ORDER BY ${_orderBy(sort, ascending)}',
    );
    return rows.map(_cardFromRow).toList();
  }

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

  // ---- Helpers -------------------------------------------------------------

  static String _lit(Object? value) {
    if (value == null) return 'NULL';
    if (value is bool) return value ? '1' : '0';
    if (value is int) return value.toString();
    if (value is double) return value.toString();
    final escaped = value.toString().replaceAll("'", "''");
    return "N'$escaped'";
  }

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
    );
  }

  static int? _asInt(Object? v) {
    if (v == null) return null;
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v.toString());
  }

  static double? _asDouble(Object? v) {
    if (v == null) return null;
    if (v is double) return v;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString());
  }

  static bool _asBool(Object? v) {
    if (v is bool) return v;
    if (v is num) return v != 0;
    final s = v?.toString().toLowerCase();
    return s == '1' || s == 'true';
  }
}
