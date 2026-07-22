import 'dart:io' show Platform;

import '../models/deck.dart';
import '../models/deck_card.dart';
import '../models/folder.dart';
import '../models/mtg_card.dart';
import 'card_backend.dart';
import 'db_config.dart';
import 'sql_server_backend.dart';
import 'sqlite_backend.dart';

// Re-export the shared types so existing imports of this file keep resolving
// CardSort, AddResult, unfiledSentinel, etc.
export 'card_backend.dart';

/// App-wide persistence facade. On [init] it prefers a local SQL Server
/// instance and automatically falls back to an embedded SQLite file when SQL
/// Server isn't installed/reachable, so the app runs on any machine. All calls
/// forward to the chosen [CardBackend].
class DatabaseService {
  DatabaseService._();
  static final DatabaseService instance = DatabaseService._();

  CardBackend? _backend;

  /// True when the app is using the local SQLite fallback (SQL Server was not
  /// available at startup).
  bool usingLocalFallback = false;

  /// Human-readable description of the active storage backend.
  String backendDescription = '';

  CardBackend get _b {
    final b = _backend;
    if (b == null) {
      throw StateError('DatabaseService.init() must be called before use.');
    }
    return b;
  }

  Future<void> init() async {
    if (_backend != null) return;
    // SQL Server over ODBC is only reachable on Windows desktop; every other
    // platform (Android, etc.) goes straight to the embedded SQLite file.
    if (Platform.isWindows) {
      try {
        final sql = SqlServerBackend();
        await sql.init();
        _backend = sql;
        usingLocalFallback = false;
        backendDescription =
            'SQL Server — ${DbConfig.server}/${DbConfig.database}';
        return;
      } on BackendUnavailableException {
        // SQL Server isn't available; use the embedded SQLite file instead.
      }
    }
    final lite = SqliteBackend();
    await lite.init();
    _backend = lite;
    usingLocalFallback = true;
    backendDescription = Platform.isWindows
        ? 'Local file (SQL Server not detected)'
        : 'Local file';
  }

  // ---- Cards (forwarded) ---------------------------------------------------

  Future<int> addCard(MtgCard card) => _b.addCard(card);
  Future<void> setCardColors(int id, String colors) =>
      _b.setCardColors(id, colors);
  Future<void> setCardColorIdentity(int id, String identity) =>
      _b.setCardColorIdentity(id, identity);
  Future<void> setCardPrice(int id, double price) =>
      _b.setCardPrice(id, price);
  Future<void> setCardDetails(
    int id, {
    required String typeLine,
    required double? cmc,
    required String oracleText,
  }) =>
      _b.setCardDetails(
          id, typeLine: typeLine, cmc: cmc, oracleText: oracleText);
  Future<List<String>> distinctSetCodes() => _b.distinctSetCodes();
  Future<void> setCardTags(int id, List<String> tags) =>
      _b.setCardTags(id, tags);
  Future<AddResult> addOrMergeCard(MtgCard card) => _b.addOrMergeCard(card);
  Future<void> moveQuantityToFolder(MtgCard card, int qty, int? destFolderId) =>
      _b.moveQuantityToFolder(card, qty, destFolderId);
  Future<List<MtgCard>> getCards({
    String? query,
    int? folderId,
    CardSort sort = CardSort.name,
    bool ascending = true,
  }) =>
      _b.getCards(
        query: query,
        folderId: folderId,
        sort: sort,
        ascending: ascending,
      );
  Future<void> updateCard(MtgCard card) => _b.updateCard(card);
  Future<void> deleteCard(int cardId) => _b.deleteCard(cardId);
  Future<void> deleteCards(List<int> cardIds) => _b.deleteCards(cardIds);

  // ---- Folders (forwarded) -------------------------------------------------

  Future<int> addFolder(String name) => _b.addFolder(name);
  Future<int> getOrCreateFolder(String name) => _b.getOrCreateFolder(name);
  Future<List<Folder>> getFolders() => _b.getFolders();
  Future<void> renameFolder(int id, String name) => _b.renameFolder(id, name);
  Future<void> deleteFolder(int id) => _b.deleteFolder(id);
  Future<Map<int, int>> folderCardCounts() => _b.folderCardCounts();

  // ---- Decks (forwarded) ---------------------------------------------------

  Future<int> addDeck(String name, String? format) =>
      _b.addDeck(name, format);
  Future<List<Deck>> getDecks() => _b.getDecks();
  Future<void> renameDeck(int id, String name) => _b.renameDeck(id, name);
  Future<void> setDeckFormat(int id, String? format) =>
      _b.setDeckFormat(id, format);
  Future<void> deleteDeck(int id) => _b.deleteDeck(id);
  Future<Map<int, int>> deckCardCounts() => _b.deckCardCounts();
  Future<int> addOrMergeDeckCard(DeckCard card) => _b.addOrMergeDeckCard(card);
  Future<List<DeckCard>> getDeckCards(int deckId) => _b.getDeckCards(deckId);
  Future<void> updateDeckCardQuantity(int id, int quantity) =>
      _b.updateDeckCardQuantity(id, quantity);
  Future<void> setDeckCardBoard(int id, String board) =>
      _b.setDeckCardBoard(id, board);
  Future<void> removeDeckCard(int id) => _b.removeDeckCard(id);
}
