const functions = require("firebase-functions/v1");
const admin = require("firebase-admin");
const Anthropic = require("@anthropic-ai/sdk");

// Free calls per user per calendar month on the shared tier. Users who hit the
// cap are told to add their own Anthropic key in the app (BYOK, unlimited).
// Override with the AI_MONTHLY_LIMIT env var without changing code.
const MONTHLY_LIMIT = Number(process.env.AI_MONTHLY_LIMIT || 20);

// A cheaper model for the tier you pay for; BYOK users get the app's premium
// model. Structured outputs are supported on Haiku 4.5.
const MODEL = "claude-haiku-4-5";

const ADVICE_SCHEMA = {
  type: "object",
  properties: {
    overall: {type: "string"},
    verdicts: {
      type: "array",
      items: {
        type: "object",
        properties: {
          name: {type: "string"},
          verdict: {type: "string", enum: ["keep", "cut", "flex"]},
          reasoning: {type: "string"},
        },
        required: ["name", "verdict", "reasoning"],
        additionalProperties: false,
      },
    },
  },
  required: ["overall", "verdicts"],
  additionalProperties: false,
};

const SYSTEM_PROMPT = [
  "You are an expert Magic: The Gathering Commander (EDH) deckbuilding advisor.",
  "A heuristic has flagged some cards in the user's deck as possible cuts. For",
  "each flagged card, decide whether it should be kept, cut, or is a flex slot,",
  "reasoning from the commander's actual strategy and the specific synergies in",
  "the deck.",
  "",
  "Crucially, a high mana value or a low overall play-rate is NOT automatically a",
  "reason to cut: many commanders reward expensive spells, graveyard value,",
  "sacrifice, or free-cast/cheat-into-play payoffs. Judge each card on how well it",
  "advances THIS commander's game plan, not on generic curve advice. If the",
  "heuristic's reason is wrong for this deck, say so and mark the card 'keep'.",
  "",
  "Write each 'reasoning' as one or two concrete, specific sentences that name the",
  "actual interaction. Use only the card text provided — do not invent abilities.",
].join("\n");

/**
 * Shared-tier AI deck advisor. Verifies the caller's Firebase ID token, enforces
 * a per-user monthly quota (stored in Realtime Database under `ai_usage/<uid>`),
 * and returns commander-aware keep/cut/flex verdicts from Claude.
 */
exports.deckAdvisor = functions
  .runWith({secrets: ["ANTHROPIC_API_KEY"], timeoutSeconds: 120})
  .https.onRequest(async (req, res) => {
    if (req.method !== "POST") {
      res.status(405).json({error: "Use POST."});
      return;
    }

    // Authenticate.
    const authz = req.get("Authorization") || "";
    const match = authz.match(/^Bearer (.+)$/);
    if (!match) {
      res.status(401).json({error: "Missing bearer token."});
      return;
    }
    let uid;
    try {
      uid = (await admin.auth().verifyIdToken(match[1])).uid;
    } catch (e) {
      res.status(401).json({error: "Invalid or expired token."});
      return;
    }

    const body = req.body || {};
    const commanders = Array.isArray(body.commanders) ? body.commanders : [];
    const candidates = Array.isArray(body.candidates) ?
      body.candidates.slice(0, 40) : [];
    const analysis = body.analysis || {};
    if (candidates.length === 0) {
      res.status(400).json({error: "No candidate cards to review."});
      return;
    }

    // Enforce the monthly quota with an atomic transaction.
    const month = new Date().toISOString().slice(0, 7); // "YYYY-MM"
    const ref = admin.database().ref(`ai_usage/${uid}`);
    let tx;
    try {
      tx = await ref.transaction((cur) => {
        const c = cur && cur.month === month ? cur : {month, count: 0};
        if (c.count >= MONTHLY_LIMIT) return; // abort → over limit
        c.count += 1;
        return c;
      });
    } catch (e) {
      console.error("quota transaction failed:", e);
      res.status(500).json({error: "Could not check your usage. Try again."});
      return;
    }
    if (!tx.committed) {
      res.status(429).json({
        code: "quota_exceeded",
        error: `You've used your ${MONTHLY_LIMIT} free AI reviews this month. ` +
          `Add your own Anthropic API key in the app for unlimited use.`,
      });
      return;
    }
    const remaining = Math.max(0, MONTHLY_LIMIT - tx.snapshot.val().count);

    const commanderText = commanders.length ?
      commanders.map((c) =>
        `- ${c.name} [${c.typeLine || ""}]: ${c.oracleText || ""}`).join("\n") :
      "(no commander specified)";
    const candidateText = candidates.map((c) => {
      const mv = c.manaValue == null ? "?" : c.manaValue;
      return `- ${c.name} (MV ${mv}) [${c.typeLine || ""}]\n` +
        `    heuristic flag: ${c.heuristicReason || ""}\n` +
        `    text: ${c.oracleText || "(none)"}`;
    }).join("\n");
    const a = analysis;
    const snapshot =
      `lands ${a.lands}/~${a.recommendedLands}, ramp ${a.ramp}, ` +
      `draw ${a.draw}, removal ${a.removal}, wipes ${a.wipe}, ` +
      `cheat ${a.cheat}, recursion ${a.recursion}, avg MV ${a.avgManaValue}`;
    const userMessage =
      `Commander(s):\n${commanderText}\n\n` +
      `Color identity: ${body.colorIdentity || "?"}\n` +
      `Format: ${body.format || "Commander"}\n` +
      `Deck snapshot: ${snapshot}\n\n` +
      `Cards a heuristic flagged as possible cuts — review each and decide ` +
      `keep / cut / flex:\n${candidateText}\n\n` +
      `First give a 2-3 sentence overall assessment, then a verdict and ` +
      `reasoning for each card.`;

    try {
      const client = new Anthropic({apiKey: process.env.ANTHROPIC_API_KEY});
      const response = await client.messages.create({
        model: MODEL,
        max_tokens: 4096,
        system: SYSTEM_PROMPT,
        messages: [{role: "user", content: userMessage}],
        output_config: {format: {type: "json_schema", schema: ADVICE_SCHEMA}},
      });
      const textBlock = response.content.find((b) => b.type === "text");
      if (!textBlock) {
        res.status(502).json({error: "No advice was returned."});
        return;
      }
      const advice = JSON.parse(textBlock.text);
      advice.remaining = remaining; // how many free reviews are left this month
      res.status(200).json(advice);
    } catch (e) {
      console.error("deckAdvisor error:", e);
      // The call failed after we counted it — refund the quota unit.
      try {
        await ref.transaction((cur) => {
          if (cur && cur.month === month && cur.count > 0) cur.count -= 1;
          return cur;
        });
      } catch (_) {}
      res.status(502).json({error: "The AI advisor is unavailable right now."});
    }
  });
