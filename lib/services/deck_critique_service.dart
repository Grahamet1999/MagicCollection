import '../models/deck_advice.dart';
import '../models/deck_card.dart';
import '../models/scryfall_parse.dart';
import 'deck_analyzer.dart';
import 'edhrec_service.dart';
import 'recommendation_service.dart';

/// A card the critique suggests cutting, with a weakness [score] (higher = worse
/// fit) and a short human-readable [reason].
class CutCandidate {
  const CutCandidate({
    required this.card,
    required this.score,
    required this.reason,
  });

  final DeckCard card;
  final double score;
  final String reason;
}

/// The full critique of a card list: structural [analysis], ranked [cuts], and
/// recommended [adds] (null when there's no commander or EDHREC has no page).
class DeckCritique {
  const DeckCritique({
    required this.analysis,
    required this.cuts,
    required this.adds,
  });

  final DeckAnalysis analysis;
  final List<CutCandidate> cuts;
  final RecommendationResult? adds;
}

/// Combines the offline [DeckAnalyzer] (structure + weak-card ranking) with the
/// EDHREC-backed [RecommendationService] (additions) into a single "what to cut
/// and what to add" critique. A single EDHREC fetch powers both the inclusion
/// signal used to rank cuts and the add recommendations.
class DeckCritiqueService {
  DeckCritiqueService(this._edhrec, this._recommend);

  final EdhrecService _edhrec;
  final RecommendationService _recommend;

  /// Critiques [mainboard] (with optional [commanders]).
  ///
  /// [isOwned] answers whether a card (lowercased name) is in the collection.
  /// When commanders are given, EDHREC is consulted for both the cut signal and
  /// the add list; offline or with no commander it degrades to analysis +
  /// heuristic cuts only.
  Future<DeckCritique> critique({
    required List<DeckCard> mainboard,
    List<DeckCard> commanders = const [],
    String? commanderColorIdentity,
    required bool Function(String nameLower) isOwned,
    DeckFormatProfile? profile,
    int maxCuts = 15,
  }) async {
    final analysis = DeckAnalyzer.analyze(
      mainboard,
      commanders: commanders,
      commanderColorIdentity: commanderColorIdentity,
      profile: profile,
    );

    final names = commanders.map((c) => c.name).toList();
    EdhrecCommander? data;
    if (names.isNotEmpty) {
      try {
        data = await _edhrec.getCommanders(names);
      } catch (_) {
        // Offline / EDHREC error — cuts fall back to heuristics, no adds.
      }
    }

    final inclusion = data == null
        ? null
        : <String, double>{
            for (final c in data.cards) c.name.toLowerCase(): c.inclusion,
          };

    final cuts = rankCuts(
      mainboard,
      analysis: analysis,
      inclusion: inclusion,
      commanderColorIdentity: commanderColorIdentity,
      maxCuts: maxCuts,
    );

    RecommendationResult? adds;
    if (data != null) {
      final exclude = {
        for (final c in [...mainboard, ...commanders]) c.name.toLowerCase(),
      };
      adds = _recommend.rankFrom(
        data,
        commanderLabel: names.join(' + '),
        isOwned: isOwned,
        excludeNames: exclude,
      );
    }

    return DeckCritique(analysis: analysis, cuts: cuts, adds: adds);
  }

  /// Ranks the weakest-fit non-land cards in [mainboard]. Pure and testable:
  /// combines the [analysis] roles, mana value, color-identity legality, and —
  /// when available — an EDHREC [inclusion] map (name → 0..1 play rate). Cards
  /// with no weakness signal are omitted.
  static List<CutCandidate> rankCuts(
    List<DeckCard> mainboard, {
    required DeckAnalysis analysis,
    Map<String, double>? inclusion,
    String? commanderColorIdentity,
    int maxCuts = 15,
  }) {
    final ci = commanderColorIdentity?.split('').toSet();
    final out = <CutCandidate>[];

    for (final c in mainboard) {
      final roles = analysis.roles[c.name.toLowerCase()] ?? const <DeckRole>{};
      if (roles.contains(DeckRole.land)) continue; // lands handled separately

      var score = 0.0;
      final reasons = <String>[];

      // Off-color identity is illegal — the strongest cut signal.
      if (ci != null && !c.colorIdentity.split('').every(ci.contains)) {
        score += 5;
        reasons.add('outside color identity');
      }

      // No functional role and not a creature body → filler.
      final hasRole = roles.isNotEmpty;
      final isCreature = primaryType(c.typeLine) == CardType.creature;
      if (!hasRole && !isCreature) {
        score += 2;
        reasons.add('no clear role');
      }

      // Expensive cards get extra scrutiny.
      if (c.cmc >= 5) {
        score += 1;
        reasons.add('high mana value (${c.cmc.toStringAsFixed(0)})');
      }

      // EDHREC play rate, when we have it.
      if (inclusion != null) {
        final inc = inclusion[c.name.toLowerCase()];
        if (inc == null) {
          score += 1;
          reasons.add('rarely played with this commander');
        } else if (inc < 0.05) {
          score += 2;
          reasons.add('in only ${(inc * 100).round()}% of decks');
        }
      }

      if (score > 0) {
        out.add(CutCandidate(
          card: c,
          score: score,
          reason: reasons.join(', '),
        ));
      }
    }

    out.sort((a, b) => b.score.compareTo(a.score));
    return out.take(maxCuts).toList();
  }
}
