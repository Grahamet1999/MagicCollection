import '../models/deck.dart';
import '../models/deck_card.dart';
import '../models/folder.dart';
import '../models/mtg_card.dart';

/// Storage operations the app needs, implemented by both the SQL Server and the
/// SQLite fallback backends. The [DatabaseService] facade picks one at startup.
abstract class CardBackend {
  /// Opens/creates the underlying store and applies any schema migrations.
  /// Throws [BackendUnavailableException] if the engine can't be reached.
  Future<void> init();

  // ---- Cards ----

  /// Inserts [card] and returns its new id.
  Future<int> addCard(MtgCard card);

  /// Overwrites the WUBRG [colors] string for the card with [id].
  Future<void> setCardColors(int id, String colors);

  /// Overwrites the WUBRG color [identity] string for the card with [id].
  Future<void> setCardColorIdentity(int id, String identity);

  /// Stores the latest USD [price] for the card with [id].
  Future<void> setCardPrice(int id, double price);

  /// Replaces the trade [tags] on the card with [id].
  Future<void> setCardTags(int id, List<String> tags);

  /// Adds [card], or if an identical printing/foil/folder already exists, bumps
  /// its quantity instead. See [AddResult] for what happened.
  Future<AddResult> addOrMergeCard(MtgCard card);

  /// Moves [qty] copies of [card] to [destFolderId] (null = unfiled), splitting
  /// or merging entries as needed so quantities stay correct.
  Future<void> moveQuantityToFolder(MtgCard card, int qty, int? destFolderId);

  /// Returns cards matching the filters, sorted by [sort]/[ascending].
  ///
  /// [query] does a name/text search; [folderId] filters to one folder, or pass
  /// [unfiledSentinel] for cards in no folder, or null for all cards.
  Future<List<MtgCard>> getCards({
    String? query,
    int? folderId,
    CardSort sort,
    bool ascending,
  });

  /// Persists every field of [card] (matched by its id).
  Future<void> updateCard(MtgCard card);

  /// Deletes the card with [cardId].
  Future<void> deleteCard(int cardId);

  /// Deletes every card in [cardIds] (bulk selection delete).
  Future<void> deleteCards(List<int> cardIds);

  // ---- Folders ----

  /// Creates a folder named [name] and returns its new id.
  Future<int> addFolder(String name);

  /// Returns the id of the folder named [name], creating it if needed.
  Future<int> getOrCreateFolder(String name);

  /// Returns all folders.
  Future<List<Folder>> getFolders();

  /// Renames the folder with [id] to [name].
  Future<void> renameFolder(int id, String name);

  /// Deletes the folder with [id]; its cards become unfiled (not deleted).
  Future<void> deleteFolder(int id);

  /// Returns a map of folder id → number of cards filed in it.
  Future<Map<int, int>> folderCardCounts();

  // ---- Decks ----

  /// Creates a deck named [name] with optional [format]; returns its new id.
  Future<int> addDeck(String name, String? format);

  /// Returns all decks.
  Future<List<Deck>> getDecks();

  /// Renames the deck with [id] to [name].
  Future<void> renameDeck(int id, String name);

  /// Sets (or clears, when null) the [format] label of the deck with [id].
  Future<void> setDeckFormat(int id, String? format);

  /// Deletes the deck with [id] and all of its deck cards.
  Future<void> deleteDeck(int id);

  /// Returns a map of deck id → total card count across its boards.
  Future<Map<int, int>> deckCardCounts();

  // ---- Deck cards ----

  /// Adds [card] to its deck, or bumps quantity if the same printing already
  /// exists on the same board; returns the affected row's id.
  Future<int> addOrMergeDeckCard(DeckCard card);

  /// Returns all cards in the deck with [deckId] (all boards).
  Future<List<DeckCard>> getDeckCards(int deckId);

  /// Sets the [quantity] of the deck card with [id].
  Future<void> updateDeckCardQuantity(int id, int quantity);

  /// Moves the deck card with [id] to [board] (commander/main/side).
  Future<void> setDeckCardBoard(int id, String board);

  /// Removes the deck card with [id].
  Future<void> removeDeckCard(int id);
}

/// Outcome of [CardBackend.addOrMergeCard].
class AddResult {
  AddResult({required this.merged, required this.quantity});

  /// True if the card was merged into an existing entry; false if newly added.
  final bool merged;

  /// The resulting quantity of the affected entry.
  final int quantity;
}

/// Sort options for the collection view.
enum CardSort { name, setNumber, color, price, quantity, dateAdded }

/// Sentinel passed as `folderId` to [CardBackend.getCards] to request only
/// cards that are not in any folder.
const int unfiledSentinel = -1;

/// Thrown by a backend's [CardBackend.init] when its storage engine isn't
/// available (e.g. SQL Server not installed/reachable), signalling the facade
/// to fall back to another backend.
class BackendUnavailableException implements Exception {
  BackendUnavailableException(this.message);
  final String message;
  @override
  String toString() => message;
}
