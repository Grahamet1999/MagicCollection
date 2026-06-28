// Headless connectivity check for the SQL Server / ODBC backend.
// Run with: dart run tool/db_check.dart
import '../lib/services/database_service.dart';
import '../lib/models/mtg_card.dart';

Future<void> main() async {
  final db = DatabaseService.instance;
  print('Connecting and ensuring schema...');
  await db.init();
  print('Connected. Database + tables ready.');

  print('Inserting a test folder...');
  final folderId = await db.addFolder('__smoketest__');
  print('  folder id = $folderId');

  print('Inserting a test card...');
  final cardId = await db.addCard(MtgCard(
    name: '__Smoke Test Bolt__',
    setCode: 'TST',
    collectorNumber: '999',
    foil: true,
    quantity: 3,
    imageUrl: 'http://example.com/x.png',
    priceUsd: 1.23,
    folderId: folderId,
  ));
  print('  card id = $cardId');

  final cards = await db.getCards(query: '__Smoke Test');
  print('Read back ${cards.length} card(s):');
  for (final c in cards) {
    print('  ${c.id}: ${c.name} ${c.setCode}#${c.collectorNumber} '
        'foil=${c.foil} qty=${c.quantity} \$${c.priceUsd} folder=${c.folderId}');
  }

  final counts = await db.folderCardCounts();
  print('Folder counts: $counts');

  print('Cleaning up test rows...');
  await db.deleteCard(cardId);
  await db.deleteFolder(folderId);
  print('Done. SQL Server backend works.');
}
