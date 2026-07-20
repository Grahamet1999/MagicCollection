import 'package:flutter/foundation.dart';

import '../models/deck.dart';
import '../models/deck_card.dart';
import '../models/scryfall_parse.dart';
import 'database_service.dart';

/// In-memory coordinator for the Decks tab, mirroring [CollectionStore].
///
/// Holds the deck list, the selected deck's cards (all boards), an ownership
/// map computed from the collection, and derived stats. Every mutator ends with
/// [load] → [notifyListeners]. Decks are independent of the collection: adding a
/// card here never changes collection quantities.
class DeckStore extends ChangeNotifier {
  DeckStore(this._db);

  final DatabaseService _db;

  List<Deck> _decks = [];
  Map<int, int> _deckCounts = {};
  int? _selectedDeckId;
  List<DeckCard> _deckCards = [];

  /// Lowercased card name → total quantity owned in the collection.
  Map<String, int> _owned = {};

  // Read-only views of the current state for the UI to render.
  List<Deck> get decks => _decks;
  Map<int, int> get deckCounts => _deckCounts;
  int? get selectedDeckId => _selectedDeckId;

  /// The currently selected deck, or null if none is selected.
  Deck? get selectedDeck {
    for (final d in _decks) {
      if (d.id == _selectedDeckId) return d;
    }
    return null;
  }

  /// Format label of the selected deck, if any.
  String? get format => selectedDeck?.format;

  /// The selected deck's commander card, or null if none is set.
  DeckCard? get commander {
    for (final c in _deckCards) {
      if (c.board == DeckBoard.commander) return c;
    }
    return null;
  }

  /// Cards on the mainboard of the selected deck.
  List<DeckCard> get mainboard =>
      _deckCards.where((c) => c.board == DeckBoard.main).toList();

  /// Cards on the sideboard of the selected deck.
  List<DeckCard> get sideboard =>
      _deckCards.where((c) => c.board == DeckBoard.side).toList();

  /// The commander's color identity (WUBRG letters), or null when no commander
  /// is set — used to filter which cards may be added to the deck.
  String? get commanderColorIdentity => commander?.colorIdentity;

  /// Sums the quantities of [cards].
  int _sumQty(Iterable<DeckCard> cards) =>
      cards.fold(0, (s, c) => s + c.quantity);

  // Card totals per board (by quantity), shown in the deck header.
  int get mainboardCount => _sumQty(mainboard);
  int get sideboardCount => _sumQty(sideboard);
  int get commanderCount => commander == null ? 0 : commander!.quantity;

  /// Total USD value across every board.
  double get deckValue =>
      _deckCards.fold(0.0, (s, c) => s + (c.priceUsd ?? 0) * c.quantity);

  /// Mainboard (+ commander) grouped by primary card type, in display order,
  /// with empty groups omitted. The commander is excluded (own section).
  Map<CardType, List<DeckCard>> get mainboardByType {
    final grouped = <CardType, List<DeckCard>>{};
    for (final type in CardType.values) {
      final cards = mainboard.where((c) => c.primaryType == type).toList();
      if (cards.isNotEmpty) grouped[type] = cards;
    }
    return grouped;
  }

  /// Pip counts per color across mainboard + commander (by quantity).
  Map<String, int> get colorBreakdown {
    final counts = {'W': 0, 'U': 0, 'B': 0, 'R': 0, 'G': 0};
    for (final c in [...mainboard, if (commander != null) commander!]) {
      for (final letter in c.colors.split('')) {
        counts[letter] = (counts[letter] ?? 0) + c.quantity;
      }
    }
    return counts;
  }

  /// CMC histogram of non-land mainboard cards, bucketed 0..7 (7 = 7+).
  Map<int, int> get manaCurve {
    final curve = {for (var i = 0; i <= 7; i++) i: 0};
    for (final c in mainboard) {
      if (c.primaryType == CardType.land) continue;
      final bucket = c.cmc >= 7 ? 7 : c.cmc.floor();
      curve[bucket] = (curve[bucket] ?? 0) + c.quantity;
    }
    return curve;
  }

  /// How many of [name] the user owns in their collection (any printing).
  int ownedCount(String name) => _owned[name.toLowerCase()] ?? 0;

  /// Reloads the deck list, the selected deck's cards, and the collection
  /// ownership map, keeping a valid selection, then notifies listeners. Every
  /// mutator below ends by calling this.
  Future<void> load() async {
    _decks = await _db.getDecks();
    _deckCounts = await _db.deckCardCounts();

    // Keep a valid selection.
    if (_selectedDeckId != null &&
        !_decks.any((d) => d.id == _selectedDeckId)) {
      _selectedDeckId = null;
    }
    _selectedDeckId ??= _decks.isNotEmpty ? _decks.first.id : null;

    _deckCards = _selectedDeckId == null
        ? []
        : await _db.getDeckCards(_selectedDeckId!);

    // Ownership by card name across the whole collection.
    final owned = <String, int>{};
    for (final c in await _db.getCards()) {
      final key = c.name.toLowerCase();
      owned[key] = (owned[key] ?? 0) + c.quantity;
    }
    _owned = owned;

    notifyListeners();
  }

  /// Selects a deck to view (or null for none) and reloads.
  Future<void> selectDeck(int? deckId) async {
    _selectedDeckId = deckId;
    await load();
  }

  /// Creates a deck, selects it, and reloads.
  Future<void> createDeck(String name, {String? format}) async {
    final id = await _db.addDeck(name, format);
    _selectedDeckId = id;
    await load();
  }

  /// Renames a deck and reloads.
  Future<void> renameDeck(int id, String name) async {
    await _db.renameDeck(id, name);
    await load();
  }

  /// Sets (or clears, when null) a deck's format label and reloads.
  Future<void> setFormat(int id, String? format) async {
    await _db.setDeckFormat(id, format);
    await load();
  }

  /// Deletes a deck (and its cards); clears the selection if it was selected.
  Future<void> deleteDeck(int id) async {
    if (_selectedDeckId == id) _selectedDeckId = null;
    await _db.deleteDeck(id);
    await load();
  }

  /// Adds a card to the selected deck (merging into a matching entry).
  Future<void> addCard(DeckCard card) async {
    await _db.addOrMergeDeckCard(card);
    await load();
  }

  /// Sets a deck card's quantity (ignored if less than 1).
  Future<void> setQuantity(int cardId, int quantity) async {
    if (quantity < 1) return;
    await _db.updateDeckCardQuantity(cardId, quantity);
    await load();
  }

  /// Moves a deck card to another board (commander/main/side).
  Future<void> setBoard(int cardId, String board) async {
    await _db.setDeckCardBoard(cardId, board);
    await load();
  }

  /// Removes a card from the selected deck.
  Future<void> removeCard(int cardId) async {
    await _db.removeDeckCard(cardId);
    await load();
  }

  /// Makes [cardId] the deck's commander, demoting any existing commander to the
  /// mainboard.
  Future<void> setCommander(int cardId) async {
    final current = commander;
    if (current != null && current.id != cardId) {
      await _db.setDeckCardBoard(current.id!, DeckBoard.main);
    }
    await _db.setDeckCardBoard(cardId, DeckBoard.commander);
    await load();
  }
}
