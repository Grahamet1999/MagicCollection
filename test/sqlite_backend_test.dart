import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mtg_collection/models/mtg_card.dart';
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
}
