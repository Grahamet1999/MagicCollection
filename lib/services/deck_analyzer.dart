import '../models/deck_advice.dart';
import '../models/deck_card.dart';
import '../models/scryfall_parse.dart';

/// Deterministic, offline deck analysis. Classifies each card into functional
/// roles (land / ramp / draw / removal / wipe) from its type line and oracle
/// text, tallies them by quantity, and compares against a [DeckFormatProfile]
/// to produce ranked advice. No network, no LLM — this is the local layer that
/// powers the "Analyze" panel and the cut half of the list critique.
///
/// Heuristics are intentionally simple and transparent; they favour recall over
/// precision (better to over-count a fringe ramp piece than to miss guidance),
/// and every finding names the cards it's based on so the user can judge.
class DeckAnalyzer {
  const DeckAnalyzer();

  /// Analyzes [mainboard] plus any [commanders] against [profile] (defaults to
  /// Commander). Pass one commander, or two for a partner / background pair.
  /// [commanderColorIdentity] (WUBRG letters, "" for a colorless command zone,
  /// null to skip the check) drives the legality finding — for pairs this is the
  /// combined identity.
  static DeckAnalysis analyze(
    List<DeckCard> mainboard, {
    List<DeckCard> commanders = const [],
    String? commanderColorIdentity,
    DeckFormatProfile? profile,
  }) {
    final prof = profile ?? DeckFormatProfile.commander;
    final cards = <DeckCard>[...mainboard, ...commanders];

    final roles = <String, Set<DeckRole>>{};
    var total = 0, lands = 0, ramp = 0, draw = 0, removal = 0, wipe = 0;
    var cheat = 0, recursion = 0;
    var creatures = 0;
    var nonLandCount = 0;
    var nonLandCmcSum = 0.0;
    final curve = {for (var i = 0; i <= 7; i++) i: 0};

    for (final c in cards) {
      final qty = c.quantity;
      total += qty;
      final type = c.typeLine.toLowerCase();
      final oracle = c.oracleText.toLowerCase();
      final r = rolesOf(type, oracle);
      if (r.isNotEmpty) roles[c.name.toLowerCase()] = r;

      if (r.contains(DeckRole.land)) {
        lands += qty;
      } else {
        nonLandCount += qty;
        nonLandCmcSum += c.cmc * qty;
        final bucket = c.cmc >= 7 ? 7 : c.cmc.floor().clamp(0, 7);
        curve[bucket] = (curve[bucket] ?? 0) + qty;
      }
      if (r.contains(DeckRole.ramp)) ramp += qty;
      if (r.contains(DeckRole.draw)) draw += qty;
      if (r.contains(DeckRole.removal)) removal += qty;
      if (r.contains(DeckRole.wipe)) wipe += qty;
      if (r.contains(DeckRole.cheat)) cheat += qty;
      if (r.contains(DeckRole.recursion)) recursion += qty;
      if (primaryType(c.typeLine) == CardType.creature) creatures += qty;
    }

    final avgCmc = nonLandCount == 0 ? 0.0 : nonLandCmcSum / nonLandCount;
    final recommendedLands = _recommendLands(prof, avgCmc, ramp);

    final findings = _buildFindings(
      prof: prof,
      total: total,
      lands: lands,
      recommendedLands: recommendedLands,
      ramp: ramp,
      draw: draw,
      removal: removal,
      wipe: wipe,
      cheat: cheat,
      recursion: recursion,
      avgCmc: avgCmc,
      cards: cards,
      commanderColorIdentity: commanderColorIdentity,
    );

    return DeckAnalysis(
      profile: prof,
      totalCards: total,
      landCount: lands,
      rampCount: ramp,
      drawCount: draw,
      removalCount: removal,
      wipeCount: wipe,
      cheatCount: cheat,
      recursionCount: recursion,
      creatureCount: creatures,
      recommendedLands: recommendedLands,
      avgManaValue: avgCmc,
      curve: curve,
      roles: roles,
      findings: findings,
    );
  }

  /// The set of roles a card fills, given a lowercased [type] line and lowercased
  /// [oracle] text. Exposed so the UI can badge individual cards.
  static Set<DeckRole> rolesOf(String type, String oracle) {
    final roles = <DeckRole>{};
    if (_isLand(type)) {
      roles.add(DeckRole.land);
      // A land can still ramp (e.g. fetches), but the count treats it as a land.
      return roles;
    }
    if (_isRamp(oracle)) roles.add(DeckRole.ramp);
    if (_isDraw(oracle)) roles.add(DeckRole.draw);
    if (_isCheat(oracle)) roles.add(DeckRole.cheat);
    if (_isRecursion(oracle)) roles.add(DeckRole.recursion);
    if (_isWipe(oracle)) {
      roles.add(DeckRole.wipe);
      roles.add(DeckRole.removal); // a board wipe is also removal
    } else if (_isRemoval(oracle)) {
      roles.add(DeckRole.removal);
    }
    return roles;
  }

  // ---- Role heuristics -----------------------------------------------------

  static bool _isLand(String type) => type.contains('land');

  static final _addMana = RegExp(r'add \{');
  static final _addManaWords =
      RegExp(r'add (one|two|three|four|five|an additional|that much|x)\b');

  static bool _isRamp(String o) {
    // Mana dorks, rocks, and rituals.
    if (_addMana.hasMatch(o)) return true;
    if (_addManaWords.hasMatch(o)) return true;
    // Land ramp: put a land onto the battlefield, whether tutored from the
    // library (Cultivate, Rampant Growth) or dropped from hand (Burgeoning).
    if (o.contains('land') &&
        o.contains('onto the battlefield') &&
        (o.contains('search your library') || o.contains('from your hand'))) {
      return true;
    }
    // Extra land drops (Exploration, Azusa, Dryad of the Ilysian Grove).
    if (o.contains('additional land')) return true;
    if (o.contains('treasure')) return true; // treasure tokens = ritual ramp
    return false;
  }

  // ---- Cheat / cost reduction ----------------------------------------------

  static final _putPermanentIntoPlay = RegExp(
      r'put[^.]*\b(creature|permanent|artifact|enchantment|planeswalker)[^.]*onto the battlefield');
  static final _costsLess = RegExp(r'cost[s]?\b[^.]{0,15}\bless\b');

  /// True for cards that cheat spells into play (reanimation, "put … onto the
  /// battlefield", free casts) or reduce their cost. Land ramp is intentionally
  /// excluded — it's handled by [_isRamp].
  static bool _isCheat(String o) {
    // Free casts: "without paying its/their mana cost".
    if (o.contains('without paying')) return true;
    // Reanimation: return a permanent from a graveyard to the battlefield.
    if (o.contains('graveyard') &&
        o.contains('to the battlefield') &&
        !o.contains('land')) {
      return true;
    }
    // Put a non-land permanent onto the battlefield (Sneak Attack, Elvish Piper).
    if (_putPermanentIntoPlay.hasMatch(o)) return true;
    // Cost reducers ("spells you cast cost {2} less to cast").
    if (_costsLess.hasMatch(o)) return true;
    return false;
  }

  // ---- Graveyard recursion -------------------------------------------------

  static final _graveyardKeywords = RegExp(
      r'\b(flashback|escape|disturb|jump-start|aftermath|retrace|unearth|encore)\b');

  /// True for cards that recur from the graveyard — "play/cast … from your
  /// graveyard" engines (Muldrotha), returning cards to hand (Regrowth), or
  /// graveyard-cast keyword mechanics. Reanimation ("… to the battlefield") is
  /// intentionally left to [_isCheat] so the two counts stay distinct.
  static bool _isRecursion(String o) {
    if (o.contains('from your graveyard')) {
      // Recasting/replaying from the yard, or returning it to hand.
      if (o.contains('play') || o.contains('cast')) return true;
      if (o.contains('to your hand')) return true;
    }
    if (_graveyardKeywords.hasMatch(o)) return true;
    return false;
  }

  static final _drawCard = RegExp(r'draws?[^.]{0,24}cards?');

  static bool _isDraw(String o) {
    if (_drawCard.hasMatch(o)) return true;
    if (o.contains('investigate')) return true;
    return false;
  }

  static final _destroyExileTarget = RegExp(r'(destroy|exile) target');
  static final _returnTarget = RegExp(r"return target .*(hand|library|owner)");
  static final _damageTo = RegExp(r'deals? \d+ damage to');
  static final _minusToTarget = RegExp(r'target creature gets [-−]');

  static bool _isRemoval(String o) {
    if (_destroyExileTarget.hasMatch(o)) return true;
    if (o.contains('counter target')) return true;
    if (_returnTarget.hasMatch(o)) return true;
    if (_damageTo.hasMatch(o) && o.contains('target')) return true;
    if (_minusToTarget.hasMatch(o)) return true;
    if (o.contains('fight')) return true;
    return false;
  }

  static final _destroyExileAll = RegExp(r'(destroy|exile) all');
  static final _damageToEach = RegExp(r'deals? \d+ damage to each');

  static bool _isWipe(String o) {
    if (_destroyExileAll.hasMatch(o)) return true;
    if (_damageToEach.hasMatch(o)) return true;
    if (o.contains('each creature') &&
        (o.contains('destroy') || o.contains('sacrifice'))) {
      return true;
    }
    if (o.contains('all creatures') &&
        (o.contains('destroy') || o.contains('exile'))) {
      return true;
    }
    return false;
  }

  // ---- Targets & findings --------------------------------------------------

  /// Recommends a land count: starts from the profile baseline, nudges up for a
  /// high average mana value and down for plentiful ramp, then clamps to a sane
  /// range around the baseline.
  static int _recommendLands(
    DeckFormatProfile prof,
    double avgCmc,
    int ramp,
  ) {
    var lands = prof.baseLands.toDouble();
    // Curve adjustment: +1 land per full point of avg CMC above 3, -1 below.
    lands += (avgCmc - 3.0);
    // Ramp lets you run slightly fewer lands: -1 per 3 ramp pieces over 6.
    if (ramp > 6) lands -= (ramp - 6) / 3.0;
    final lo = prof.baseLands - 5;
    final hi = prof.baseLands + 4;
    return lands.round().clamp(lo, hi);
  }

  static List<DeckFinding> _buildFindings({
    required DeckFormatProfile prof,
    required int total,
    required int lands,
    required int recommendedLands,
    required int ramp,
    required int draw,
    required int removal,
    required int wipe,
    required int cheat,
    required int recursion,
    required double avgCmc,
    required List<DeckCard> cards,
    required String? commanderColorIdentity,
  }) {
    final out = <DeckFinding>[];

    // Legality: off-color-identity cards (Commander-style formats only).
    if (commanderColorIdentity != null) {
      final ci = commanderColorIdentity.split('').toSet();
      final offColor = cards
          .where((c) => !c.colorIdentity
              .split('')
              .every((letter) => ci.contains(letter)))
          .map((c) => c.name)
          .toList();
      if (offColor.isNotEmpty) {
        out.add(DeckFinding(
          severity: FindingSeverity.warning,
          category: 'legality',
          message:
              '${offColor.length} card(s) fall outside the commander\'s color '
              'identity and are not legal in the deck.',
          cards: offColor,
        ));
      }
    }

    // Deck size (only meaningful for singleton formats with a fixed size).
    if (prof.singleton && total != prof.deckSize) {
      final diff = prof.deckSize - total;
      out.add(DeckFinding(
        severity: FindingSeverity.warning,
        category: 'size',
        message: diff > 0
            ? 'Deck is $diff card(s) short of ${prof.deckSize}.'
            : 'Deck is ${-diff} card(s) over ${prof.deckSize}.',
      ));
    }

    // Lands.
    final landGap = recommendedLands - lands;
    if (landGap >= 3) {
      out.add(DeckFinding(
        severity: FindingSeverity.warning,
        category: 'lands',
        message:
            'Only $lands lands. For this curve (avg MV ${avgCmc.toStringAsFixed(1)}) '
            'aim for about $recommendedLands — add $landGap more.',
      ));
    } else if (landGap <= -3) {
      out.add(DeckFinding(
        severity: FindingSeverity.suggestion,
        category: 'lands',
        message:
            '$lands lands may be more than this curve needs (about '
            '$recommendedLands is typical). Consider trimming ${-landGap}.',
      ));
    } else {
      out.add(DeckFinding(
        severity: FindingSeverity.info,
        category: 'lands',
        message: '$lands lands — about right for this curve '
            '(target ~$recommendedLands).',
      ));
    }

    // Ramp / draw / removal shortfalls (thresholds are 0 for non-Commander).
    if (prof.minRamp > 0) {
      out.add(_countFinding(
        category: 'ramp',
        label: 'ramp piece',
        have: ramp,
        want: prof.minRamp,
      ));
    }
    if (prof.minDraw > 0) {
      out.add(_countFinding(
        category: 'draw',
        label: 'card-draw source',
        have: draw,
        want: prof.minDraw,
      ));
    }
    if (prof.minRemoval > 0) {
      out.add(_countFinding(
        category: 'removal',
        label: 'removal spell',
        have: removal,
        want: prof.minRemoval,
      ));
      if (wipe == 0 && prof.singleton) {
        out.add(const DeckFinding(
          severity: FindingSeverity.suggestion,
          category: 'removal',
          message: 'No board wipes detected — most decks want 1–3 to reset a '
              'losing board.',
        ));
      }
    }

    // Cheat / cost reduction — informational, only when the deck runs some.
    if (cheat > 0) {
      out.add(DeckFinding(
        severity: FindingSeverity.info,
        category: 'cheat',
        message: '$cheat effect(s) that cheat spells into play or reduce their '
            'cost (reanimation, free casts, cost reducers).',
      ));
    }

    // Graveyard recursion — informational, only when the deck runs some.
    if (recursion > 0) {
      out.add(DeckFinding(
        severity: FindingSeverity.info,
        category: 'recursion',
        message: '$recursion graveyard-recursion effect(s) (play/cast from the '
            'graveyard, flashback/escape, or return to hand).',
      ));
    }

    // Curve.
    if (avgCmc >= 3.6 && ramp < prof.minRamp) {
      out.add(DeckFinding(
        severity: FindingSeverity.suggestion,
        category: 'curve',
        message:
            'High average mana value (${avgCmc.toStringAsFixed(1)}) with light '
            'ramp — the deck may be slow to get going.',
      ));
    }

    // Most-severe first, keep insertion order within a severity.
    out.sort((a, b) => b.severity.index.compareTo(a.severity.index));
    return out;
  }

  /// Builds a shortfall/OK finding for a simple "have vs want" count.
  static DeckFinding _countFinding({
    required String category,
    required String label,
    required int have,
    required int want,
  }) {
    if (have < want) {
      final gap = want - have;
      return DeckFinding(
        severity: have < want - 2
            ? FindingSeverity.warning
            : FindingSeverity.suggestion,
        category: category,
        message: '$have ${label}s — aim for about $want. Add $gap more.',
      );
    }
    return DeckFinding(
      severity: FindingSeverity.info,
      category: category,
      message: '$have ${label}s — a healthy amount.',
    );
  }
}
