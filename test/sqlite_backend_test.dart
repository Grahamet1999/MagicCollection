import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mtg_collection/models/deck_card.dart';
import 'package:mtg_collection/models/mtg_card.dart';
import 'package:mtg_collection/models/scryfall_parse.dart';
import 'package:mtg_collection/services/card_backend.dart';
import 'package:mtg_collection/services/sqlite_backend.dart';

void main() {
  late SqliteBackend db;
  late String tmpPath;

  setUp(() async {
    tmpPath =
        '${Directory.systemTemp.path}/mtg_test_${DateTime.now().microsecondsSinceEpoch}.db';
    db = SqliteBackend();
    await db.init(path: tmpPath);
  });

  tearDown(() async {
    await db.close();
    final f = File(tmpPath);
    if (f.existsSync()) f.deleteSync();
  });

  test('add then merge same printing (unfiled)', () async {
    final r1 = await db.addOrMergeCard(const MtgCard(
        name: 'Bolt', setCode: 'A', collectorNumber: '1', colors: 'R'));
    expect(r1.merged, false);
    expect(r1.quantity, 1);

    final r2 = await db.addOrMergeCard(const MtgCard(
        name: 'Bolt',
        setCode: 'A',
        collectorNumber: '1',
        quantity: 2,
        colors: 'R'));
    expect(r2.merged, true);
    expect(r2.quantity, 3);
  });

  test('split a stack across folders', () async {
    await db.addOrMergeCard(const MtgCard(
        name: 'Bolt', setCode: 'A', collectorNumber: '1', quantity: 3));
    final fA = await db.addFolder('A');
    final fB = await db.addFolder('B');

    var unfiled = (await db.getCards(folderId: unfiledSentinel)).first;
    await db.moveQuantityToFolder(unfiled, 1, fA);
    unfiled = (await db.getCards(folderId: unfiledSentinel)).first;
    await db.moveQuantityToFolder(unfiled, 2, fB);

    final counts = await db.folderCardCounts();
    expect(counts[fA], 1);
    expect(counts[fB], 1);
    final total =
        (await db.getCards()).fold<int>(0, (s, c) => s + c.quantity);
    expect(total, 3);
  });

  test('color sort orders W,U,B,R,G then colorless', () async {
    await db.addCard(const MtgCard(
        name: 'Plains', setCode: 'A', collectorNumber: '1', colors: ''));
    await db.addCard(const MtgCard(
        name: 'Island', setCode: 'A', collectorNumber: '2', colors: 'U'));
    await db.addCard(const MtgCard(
        name: 'Plains2', setCode: 'A', collectorNumber: '3', colors: 'W'));

    final ranks = (await db.getCards(sort: CardSort.color, ascending: true))
        .map((c) => MtgCard.colorRank(c.colors))
        .toList();
    final sorted = [...ranks]..sort();
    expect(ranks, sorted); // non-decreasing rank
    expect(ranks.first, 1); // White first
    expect(ranks.last, 7); // colorless last
  });

  test('primaryType buckets by priority', () {
    expect(primaryType('Legendary Creature — Elf Druid'), CardType.creature);
    expect(primaryType('Artifact Land'), CardType.land);
    expect(primaryType('Artifact Creature — Golem'), CardType.creature);
    expect(primaryType('Instant'), CardType.instant);
    expect(primaryType('Enchantment — Aura'), CardType.enchantment);
  });

  DeckCard deckCard(int deckId,
          {String name = 'X',
          String number = '1',
          bool foil = false,
          int qty = 1,
          String board = DeckBoard.main}) =>
      DeckCard(
        deckId: deckId,
        name: name,
        setCode: 'A',
        collectorNumber: number,
        foil: foil,
        quantity: qty,
        board: board,
      );

  test('deck: add, merge, move board, counts', () async {
    final deckId = await db.addDeck('Test', 'Commander');
    expect((await db.getDecks()).single.name, 'Test');

    // Add + merge same printing on the same board.
    await db.addOrMergeDeckCard(deckCard(deckId, name: 'Sol Ring', qty: 1));
    await db.addOrMergeDeckCard(deckCard(deckId, name: 'Sol Ring', qty: 2));
    var cards = await db.getDeckCards(deckId);
    expect(cards.length, 1);
    expect(cards.single.quantity, 3);

    // A different board is a separate entry.
    await db.addOrMergeDeckCard(
        deckCard(deckId, name: 'Sol Ring', board: DeckBoard.side));
    cards = await db.getDeckCards(deckId);
    expect(cards.length, 2);

    // Move the mainboard entry to commander.
    final mainCard =
        cards.firstWhere((c) => c.board == DeckBoard.main);
    await db.setDeckCardBoard(mainCard.id!, DeckBoard.commander);
    cards = await db.getDeckCards(deckId);
    expect(cards.firstWhere((c) => c.id == mainCard.id).board,
        DeckBoard.commander);

    // Counts (sum of quantities): 3 (commander) + 1 (side) = 4.
    expect((await db.deckCardCounts())[deckId], 4);
  });

  test('deck delete cascades its cards', () async {
    final deckId = await db.addDeck('Temp', null);
    await db.addOrMergeDeckCard(deckCard(deckId, name: 'A'));
    await db.addOrMergeDeckCard(deckCard(deckId, name: 'B', number: '2'));
    expect((await db.getDeckCards(deckId)).length, 2);

    await db.deleteDeck(deckId);
    expect(await db.getDecks(), isEmpty);
    expect(await db.getDeckCards(deckId), isEmpty); // cascaded
  });
}
