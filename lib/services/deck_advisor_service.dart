import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/deck_advice.dart';
import '../models/deck_card.dart';
import 'app_settings.dart';
import 'deck_critique_service.dart';

/// A commander-aware verdict for one card, returned by the AI advisor.
class CardVerdict {
  const CardVerdict({
    required this.name,
    required this.verdict,
    required this.reasoning,
  });

  final String name;

  /// One of `keep`, `cut`, or `flex`.
  final String verdict;

  /// One or two sentences of commander-aware reasoning.
  final String reasoning;

  static CardVerdict? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final name = raw['name'];
    if (name is! String) return null;
    return CardVerdict(
      name: name,
      verdict: (raw['verdict'] as String? ?? 'flex').toLowerCase(),
      reasoning: raw['reasoning'] as String? ?? '',
    );
  }
}

/// The AI advisor's response: an overall assessment plus per-card verdicts.
class CritiqueAdvice {
  const CritiqueAdvice({required this.overall, required this.verdicts});

  final String overall;
  final List<CardVerdict> verdicts;

  /// The verdict for [name] (case-insensitive), or null.
  CardVerdict? forName(String name) {
    final key = name.toLowerCase();
    for (final v in verdicts) {
      if (v.name.toLowerCase() == key) return v;
    }
    return null;
  }

  factory CritiqueAdvice.fromJson(Map<String, dynamic> json) {
    final list = json['verdicts'];
    return CritiqueAdvice(
      overall: json['overall'] as String? ?? '',
      verdicts: [
        if (list is List)
          for (final v in list)
            if (CardVerdict.fromJson(v) case final cv?) cv,
      ],
    );
  }
}

/// Adds natural-language, commander-aware reasoning on top of the deterministic
/// critique by calling Claude directly (Anthropic Messages API).
///
/// The user's own API key lives in [AppSettings] (on-device, entered by them),
/// and the call goes straight to `api.anthropic.com` — no backend. This is a
/// native HTTP client, so CORS doesn't apply. If you'd rather keep the key
/// off-device, a server proxy would be the alternative.
class DeckAdvisorService {
  DeckAdvisorService({http.Client? client})
      : _client = client ?? http.Client();

  final http.Client _client;

  static const _endpoint = 'https://api.anthropic.com/v1/messages';
  static const _model = 'claude-opus-5';

  static const _systemPrompt =
      "You are an expert Magic: The Gathering Commander (EDH) deckbuilding "
      "advisor. A heuristic has flagged some cards in the user's deck as "
      "possible cuts. For each flagged card, decide whether it should be kept, "
      "cut, or is a flex slot, reasoning from the commander's actual strategy "
      "and the specific synergies in the deck.\n\n"
      "Crucially, a high mana value or a low overall play-rate is NOT "
      "automatically a reason to cut: many commanders reward expensive spells, "
      "graveyard value, sacrifice, or free-cast/cheat-into-play payoffs. Judge "
      "each card on how well it advances THIS commander's game plan, not on "
      "generic curve advice. If the heuristic's reason is wrong for this deck, "
      "say so and mark the card 'keep'.\n\n"
      "Write each 'reasoning' as one or two concrete, specific sentences that "
      "name the actual interaction. Use only the card text provided — do not "
      "invent abilities the text doesn't show.";

  static const Map<String, dynamic> _adviceSchema = {
    'type': 'object',
    'properties': {
      'overall': {'type': 'string'},
      'verdicts': {
        'type': 'array',
        'items': {
          'type': 'object',
          'properties': {
            'name': {'type': 'string'},
            'verdict': {
              'type': 'string',
              'enum': ['keep', 'cut', 'flex'],
            },
            'reasoning': {'type': 'string'},
          },
          'required': ['name', 'verdict', 'reasoning'],
          'additionalProperties': false,
        },
      },
    },
    'required': ['overall', 'verdicts'],
    'additionalProperties': false,
  };

  /// True when an Anthropic API key is configured.
  bool get available => AppSettings.instance.hasAnthropicKey;

  /// Asks Claude to review the heuristic [candidates] for a deck with the given
  /// [commanders] and [analysis], returning keep/cut/flex verdicts.
  Future<CritiqueAdvice> reviewCuts({
    required List<DeckCard> commanders,
    required String? colorIdentity,
    required String format,
    required DeckAnalysis analysis,
    required List<CutCandidate> candidates,
  }) async {
    final key = AppSettings.instance.anthropicKey;
    if (key == null || key.isEmpty) {
      throw DeckAdvisorException('Add your Anthropic API key to use AI advice.');
    }
    if (candidates.isEmpty) {
      throw DeckAdvisorException('Nothing flagged to review.');
    }

    final capped = candidates.take(40).toList();
    final userMessage = _buildUserMessage(
      commanders: commanders,
      colorIdentity: colorIdentity,
      format: format,
      analysis: analysis,
      candidates: capped,
    );

    final payload = jsonEncode({
      'model': _model,
      'max_tokens': 8000,
      'system': _systemPrompt,
      'messages': [
        {'role': 'user', 'content': userMessage},
      ],
      'output_config': {
        'format': {'type': 'json_schema', 'schema': _adviceSchema},
      },
    });

    final http.Response res;
    try {
      res = await _client.post(
        Uri.parse(_endpoint),
        headers: {
          'content-type': 'application/json',
          'x-api-key': key,
          'anthropic-version': '2023-06-01',
        },
        body: payload,
      );
    } catch (e) {
      throw DeckAdvisorException('Could not reach the Anthropic API.');
    }

    if (res.statusCode != 200) {
      throw DeckAdvisorException(_messageFor(res));
    }

    final Map<String, dynamic> body;
    try {
      body = jsonDecode(res.body) as Map<String, dynamic>;
    } catch (_) {
      throw DeckAdvisorException('The AI advisor returned an unexpected reply.');
    }

    if (body['stop_reason'] == 'refusal') {
      throw DeckAdvisorException('The request was declined by the safety filter.');
    }

    // With thinking on, a thinking block may precede the JSON text block.
    final content = body['content'];
    String? text;
    if (content is List) {
      for (final b in content) {
        if (b is Map && b['type'] == 'text' && b['text'] is String) {
          text = b['text'] as String;
          break;
        }
      }
    }
    if (text == null) {
      throw DeckAdvisorException('No advice was returned.');
    }
    try {
      return CritiqueAdvice.fromJson(jsonDecode(text) as Map<String, dynamic>);
    } catch (_) {
      throw DeckAdvisorException('Could not parse the AI advisor reply.');
    }
  }

  String _buildUserMessage({
    required List<DeckCard> commanders,
    required String? colorIdentity,
    required String format,
    required DeckAnalysis analysis,
    required List<CutCandidate> candidates,
  }) {
    final commanderText = commanders.isEmpty
        ? '(no commander specified)'
        : commanders
            .map((c) => '- ${c.name} [${c.typeLine}]: ${c.oracleText}')
            .join('\n');

    final candidateText = candidates.map((c) {
      final card = c.card;
      return '- ${card.name} (MV ${card.cmc.toStringAsFixed(0)}) '
          '[${card.typeLine}]\n'
          '    heuristic flag: ${c.reason}\n'
          '    text: ${card.oracleText.isEmpty ? "(none)" : card.oracleText}';
    }).join('\n');

    final a = analysis;
    final snapshot = 'lands ${a.landCount}/~${a.recommendedLands}, '
        'ramp ${a.rampCount}, draw ${a.drawCount}, removal ${a.removalCount}, '
        'wipes ${a.wipeCount}, cheat ${a.cheatCount}, '
        'recursion ${a.recursionCount}, avg MV '
        '${a.avgManaValue.toStringAsFixed(1)}';

    return 'Commander(s):\n$commanderText\n\n'
        'Color identity: ${colorIdentity ?? "?"}\n'
        'Format: $format\n'
        'Deck snapshot: $snapshot\n\n'
        'Cards a heuristic flagged as possible cuts — review each and decide '
        'keep / cut / flex:\n$candidateText\n\n'
        'First give a 2-3 sentence overall assessment of how these flagged '
        'cards fit the commander, then a verdict and reasoning for each card.';
  }

  /// Extracts Anthropic's error message, else a generic one.
  String _messageFor(http.Response res) {
    try {
      final body = jsonDecode(res.body);
      if (body is Map && body['error'] is Map) {
        final msg = (body['error'] as Map)['message'];
        if (msg is String && msg.isNotEmpty) return msg;
      }
    } catch (_) {}
    if (res.statusCode == 401) {
      return 'Anthropic rejected the API key — check it in AI settings.';
    }
    return 'AI advisor request failed (HTTP ${res.statusCode}).';
  }

  void dispose() => _client.close();
}

/// A user-facing error from the AI advisor.
class DeckAdvisorException implements Exception {
  DeckAdvisorException(this.message);
  final String message;
  @override
  String toString() => message;
}
