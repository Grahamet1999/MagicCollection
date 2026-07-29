import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/deck_advice.dart';
import '../models/deck_card.dart';
import 'app_settings.dart';
import 'auth_service.dart';
import 'deck_critique_service.dart';
import 'firebase_config.dart';

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

/// The AI advisor's response: an overall assessment plus per-card verdicts, and
/// (on the shared free tier) how many free reviews remain this month.
class CritiqueAdvice {
  const CritiqueAdvice({
    required this.overall,
    required this.verdicts,
    this.remaining,
  });

  final String overall;
  final List<CardVerdict> verdicts;

  /// Free shared-tier reviews left this month, or null for BYOK (unlimited).
  final int? remaining;

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
      remaining: (json['remaining'] as num?)?.toInt(),
      verdicts: [
        if (list is List)
          for (final v in list)
            if (CardVerdict.fromJson(v) case final cv?) cv,
      ],
    );
  }
}

/// Adds natural-language, commander-aware reasoning on top of the deterministic
/// critique. Hybrid transport:
///
/// - **BYOK** — if the user set their own Anthropic key in [AppSettings], calls
///   `api.anthropic.com` directly (unlimited, their spend, premium model).
/// - **Shared free tier** — otherwise, if signed in, calls the `deckAdvisor`
///   Cloud Function, which holds the app owner's key and enforces a per-user
///   monthly quota. When the quota is exhausted the app nudges the user to BYOK.
class DeckAdvisorService {
  DeckAdvisorService(this._auth, {http.Client? client})
      : _client = client ?? http.Client();

  final AuthService _auth;
  final http.Client _client;

  static const _anthropicEndpoint = 'https://api.anthropic.com/v1/messages';
  static const _byokModel = 'claude-opus-5';

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

  /// True when advice can be requested: the user has their own key (BYOK) or is
  /// signed in (shared free tier).
  bool get available =>
      AppSettings.instance.hasAnthropicKey ||
      (FirebaseConfig.isConfigured && _auth.isSignedIn);

  /// True when the shared free tier (not BYOK) would be used for the next call.
  bool get usingFreeTier =>
      !AppSettings.instance.hasAnthropicKey &&
      FirebaseConfig.isConfigured &&
      _auth.isSignedIn;

  /// Reviews the heuristic [candidates] and returns keep/cut/flex verdicts,
  /// routing to BYOK or the shared free tier automatically.
  Future<CritiqueAdvice> reviewCuts({
    required List<DeckCard> commanders,
    required String? colorIdentity,
    required String format,
    required DeckAnalysis analysis,
    required List<CutCandidate> candidates,
  }) async {
    if (candidates.isEmpty) {
      throw DeckAdvisorException('Nothing flagged to review.');
    }
    final capped = candidates.take(40).toList();

    if (AppSettings.instance.hasAnthropicKey) {
      return _reviewDirect(
          commanders, colorIdentity, format, analysis, capped);
    }
    if (FirebaseConfig.isConfigured && _auth.isSignedIn) {
      return _reviewViaProxy(
          commanders, colorIdentity, format, analysis, capped);
    }
    throw DeckAdvisorException(
        'Sign in for free AI advice, or add your own Anthropic key.');
  }

  // ---- BYOK: direct to Anthropic ------------------------------------------

  Future<CritiqueAdvice> _reviewDirect(
    List<DeckCard> commanders,
    String? colorIdentity,
    String format,
    DeckAnalysis analysis,
    List<CutCandidate> candidates,
  ) async {
    final key = AppSettings.instance.anthropicKey!;
    final userMessage = _buildUserMessage(
        commanders, colorIdentity, format, analysis, candidates);
    final payload = jsonEncode({
      'model': _byokModel,
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
        Uri.parse(_anthropicEndpoint),
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
      throw DeckAdvisorException(
          _anthropicError(res) ?? _statusMessage(res.statusCode, byok: true));
    }
    return _parseAnthropicResponse(res.body);
  }

  CritiqueAdvice _parseAnthropicResponse(String bodyText) {
    final Map<String, dynamic> body;
    try {
      body = jsonDecode(bodyText) as Map<String, dynamic>;
    } catch (_) {
      throw DeckAdvisorException('The AI advisor returned an unexpected reply.');
    }
    if (body['stop_reason'] == 'refusal') {
      throw DeckAdvisorException('The request was declined by the safety filter.');
    }
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
    if (text == null) throw DeckAdvisorException('No advice was returned.');
    try {
      return CritiqueAdvice.fromJson(jsonDecode(text) as Map<String, dynamic>);
    } catch (_) {
      throw DeckAdvisorException('Could not parse the AI advisor reply.');
    }
  }

  // ---- Shared free tier: via the Cloud Function ---------------------------

  Future<CritiqueAdvice> _reviewViaProxy(
    List<DeckCard> commanders,
    String? colorIdentity,
    String format,
    DeckAnalysis analysis,
    List<CutCandidate> candidates,
  ) async {
    final token = await _auth.idToken();
    final payload = jsonEncode({
      'commanders': [
        for (final c in commanders)
          {'name': c.name, 'typeLine': c.typeLine, 'oracleText': c.oracleText},
      ],
      'colorIdentity': colorIdentity,
      'format': format,
      'analysis': {
        'lands': analysis.landCount,
        'recommendedLands': analysis.recommendedLands,
        'ramp': analysis.rampCount,
        'draw': analysis.drawCount,
        'removal': analysis.removalCount,
        'wipe': analysis.wipeCount,
        'cheat': analysis.cheatCount,
        'recursion': analysis.recursionCount,
        'avgManaValue': analysis.avgManaValue,
      },
      'candidates': [
        for (final c in candidates)
          {
            'name': c.card.name,
            'typeLine': c.card.typeLine,
            'manaValue': c.card.cmc,
            'oracleText': c.card.oracleText,
            'heuristicReason': c.reason,
          },
      ],
    });

    final http.Response res;
    try {
      res = await _client.post(
        Uri.parse('${FirebaseConfig.functionsBase}/deckAdvisor'),
        headers: {
          'content-type': 'application/json',
          'Authorization': 'Bearer $token',
        },
        body: payload,
      );
    } catch (e) {
      throw DeckAdvisorException(
          'Could not reach the AI advisor. Check your connection.');
    }

    if (res.statusCode == 429) {
      throw DeckAdvisorException(
        _proxyError(res) ?? 'Free AI limit reached.',
        quotaExceeded: true,
      );
    }
    if (res.statusCode != 200) {
      throw DeckAdvisorException(
          _proxyError(res) ?? _statusMessage(res.statusCode, byok: false));
    }
    try {
      return CritiqueAdvice.fromJson(
          jsonDecode(res.body) as Map<String, dynamic>);
    } catch (_) {
      throw DeckAdvisorException('The AI advisor returned an unexpected reply.');
    }
  }

  // ---- Shared prompt + error helpers --------------------------------------

  String _buildUserMessage(
    List<DeckCard> commanders,
    String? colorIdentity,
    String format,
    DeckAnalysis analysis,
    List<CutCandidate> candidates,
  ) {
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

  String? _anthropicError(http.Response res) {
    try {
      final body = jsonDecode(res.body);
      if (body is Map && body['error'] is Map) {
        final msg = (body['error'] as Map)['message'];
        if (msg is String && msg.isNotEmpty) return msg;
      }
    } catch (_) {}
    return null;
  }

  String? _proxyError(http.Response res) {
    try {
      final body = jsonDecode(res.body);
      if (body is Map && body['error'] is String) return body['error'] as String;
    } catch (_) {}
    return null;
  }

  String _statusMessage(int code, {required bool byok}) {
    if (code == 401) {
      return byok
          ? 'Anthropic rejected the API key — check it in AI settings.'
          : 'Please sign in again to use AI advice.';
    }
    return 'AI advisor request failed (HTTP $code).';
  }

  void dispose() => _client.close();
}

/// A user-facing error from the AI advisor.
class DeckAdvisorException implements Exception {
  DeckAdvisorException(this.message, {this.quotaExceeded = false});
  final String message;

  /// True when the shared free-tier monthly quota is exhausted (offer BYOK).
  final bool quotaExceeded;

  @override
  String toString() => message;
}
