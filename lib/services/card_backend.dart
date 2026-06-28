import '../models/folder.dart';
import '../models/mtg_card.dart';

/// Storage operations the app needs, implemented by both the SQL Server and the
/// SQLite fallback backends. The [DatabaseService] facade picks one at startup.
abstract class CardBackend {
  Future<void> init();

  // Cards
  Future<int> addCard(MtgCard card);
  Future<void> setCardColors(int id, String colors);
  Future<void> setCardPrice(int id, double price);
  Future<AddResult> addOrMergeCard(MtgCard card);
  Future<void> moveQuantityToFolder(MtgCard card, int qty, int? destFolderId);
  Future<List<MtgCard>> getCards({
    String? query,
    int? folderId,
    CardSort sort,
    bool ascending,
  });
  Future<void> updateCard(MtgCard card);
  Future<void> deleteCard(int cardId);
  Future<void> deleteCards(List<int> cardIds);

  // Folders
  Future<int> addFolder(String name);
  Future<int> getOrCreateFolder(String name);
  Future<List<Folder>> getFolders();
  Future<void> renameFolder(int id, String name);
  Future<void> deleteFolder(int id);
  Future<Map<int, int>> folderCardCounts();
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
