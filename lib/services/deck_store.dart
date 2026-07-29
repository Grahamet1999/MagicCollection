import 'package:flutter/foundation.dart';

import '../models/deck.dart';
import '../models/deck_card.dart';
import '../models/scryfall_parse.dart';
import 'collection_store.dart' show DetailBackfillResult;
import 'commander_rules.dart';
import 'database_service.dart';
import 'scryfall_service.dart';

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

  /// The selected deck's commanders (one, or two for Partner / Background /
  /// Friends-forever pairings), in insertion order.
  List<DeckCard> get commanders =>
      _deckCards.where((c) => c.board == DeckBoard.commander).toList();

  /// The primary commander card, or null if none is set. For partner decks this
  /// is the first of [commanders]; prefer [commanders] when both matter.
  DeckCard? get commander {
    final cs = commanders;
    return cs.isEmpty ? null : cs.first;
  }

  /// The commanders' display names.
  List<String> get commanderNames =>
      commanders.map((c) => c.name).toList();

  /// Every card in the selected deck, across all boards.
  List<DeckCard> get allCards => List.unmodifiable(_deckCards);

  /// Cards on the mainboard of the selected deck.
  List<DeckCard> get mainboard =>
      _deckCards.where((c) => c.board == DeckBoard.main).toList();

  /// Cards on the sideboard of the selected deck.
  List<DeckCard> get sideboard =>
      _deckCards.where((c) => c.board == DeckBoard.side).toList();

  /// The combined color identity of all commanders (WUBRG letters), or null when
  /// none is set — used to filter which cards may be added to the deck. For
  /// partner/background pairs this is the union of both identities.
  String? get commanderColorIdentity {
    final cs = commanders;
    if (cs.isEmpty) return null;
    return CommanderRules.combinedColorIdentity(cs);
  }

  /// Sums the quantities of [cards].
  int _sumQty(Iterable<DeckCard> cards) =>
      cards.fold(0, (s, c) => s + c.quantity);

  // Card totals per board (by quantity), shown in the deck header.
  int get mainboardCount => _sumQty(mainboard);
  int get sideboardCount => _sumQty(sideboard);
  int get commanderCount => _sumQty(commanders);

  /// Total USD value across every board.
  double get deckValue =>
      _deckCards.fold(0.0, (s, c) => s + (c.priceUsd ?? 0) * c.quantity);

  /// Pip counts per color across mainboard + commander (by quantity).
  Map<String, int> get colorBreakdown {
    final counts = {'W': 0, 'U': 0, 'B': 0, 'R': 0, 'G': 0};
    for (final c in [...mainboard, ...commanders]) {
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

  /// Backfills oracle text (and other Scryfall detail fields) from Scryfall for
  /// the selected deck's cards missing them — rows created before oracle text
  /// was captured. Enables accurate ramp/draw/removal classification in the deck
  /// analyzer. Returns how many rows were updated out of how many needed it.
  /// Mirrors [CollectionStore.backfillCardDetails].
  Future<DetailBackfillResult> backfillSelectedDeckDetails({
    void Function(int done, int total)? onProgress,
  }) async {
    if (_selectedDeckId == null) {
      return const DetailBackfillResult(updated: 0, total: 0);
    }
    final missing =
        _deckCards.where((c) => c.oracleText.isEmpty && c.id != null).toList();
    if (missing.isEmpty) return const DetailBackfillResult(updated: 0, total: 0);

    // One lookup per unique printing.
    final byKey = <String, Map<String, String>>{};
    for (final c in missing) {
      byKey['${c.setCode.toLowerCase()}|${c.collectorNumber}'] = {
        'set': c.setCode.toLowerCase(),
        'collector_number': c.collectorNumber,
      };
    }
    final identifiers = byKey.values.toList();
    final total = identifiers.length;
    onProgress?.call(0, total);

    final scryfall = ScryfallService();
    try {
      final jsonByKey = <String, Map<String, dynamic>>{};
      const chunkSize = 75;
      for (var i = 0; i < identifiers.length; i += chunkSize) {
        final end = (i + chunkSize < identifiers.length)
            ? i + chunkSize
            : identifiers.length;
        final result =
            await scryfall.getCollection(identifiers.sublist(i, end));
        for (final j in result.found) {
          jsonByKey['${(j['set'] as String).toLowerCase()}'
              '|${j['collector_number']}'] = j;
        }
        onProgress?.call(end, total);
      }

      var updated = 0;
      for (final c in missing) {
        final json =
            jsonByKey['${c.setCode.toLowerCase()}|${c.collectorNumber}'];
        if (json == null) continue;
        await _db.setDeckCardDetails(
          c.id!,
          typeLine: typeLineFromScryfall(json),
          cmc: cmcFromScryfall(json),
          colors: colorsFromScryfall(json),
          colorIdentity: colorIdentityFromScryfall(json),
          oracleText: oracleTextFromScryfall(json),
        );
        updated++;
      }
      await load();
      return DetailBackfillResult(updated: updated, total: missing.length);
    } finally {
      scryfall.dispose();
    }
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

  /// Makes [cardId] the deck's commander. If exactly one commander is already
  /// set and it forms a legal pairing with the target (Partner / Friends forever
  /// / Background), both are kept as co-commanders; otherwise existing
  /// commanders are demoted to the mainboard. A deck holds at most two
  /// commanders.
  Future<void> setCommander(int cardId) async {
    DeckCard? target;
    for (final c in _deckCards) {
      if (c.id == cardId) {
        target = c;
        break;
      }
    }
    final existing = commanders;
    // Keep a single existing commander only if it legally pairs with the target.
    final keepPartner = target != null &&
        existing.length == 1 &&
        existing.first.id != cardId &&
        CommanderRules.canPair(existing.first, target);
    for (final c in existing) {
      if (c.id == cardId) continue;
      if (keepPartner && c.id == existing.first.id) continue;
      await _db.setDeckCardBoard(c.id!, DeckBoard.main);
    }
    await _db.setDeckCardBoard(cardId, DeckBoard.commander);
    await load();
  }
}
