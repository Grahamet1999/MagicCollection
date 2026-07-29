# AI Deck Advisor — hybrid setup (free tier + BYOK)

The "Explain with AI" feature has two paths:

- **BYOK** — a user who pastes their own Anthropic API key in the app calls
  Claude directly (unlimited, their spend). No setup needed by you.
- **Shared free tier** — a signed-in user with *no* key uses the `deckAdvisor`
  Cloud Function, which holds **your** Anthropic key (a Firebase secret) and
  enforces a **per-user monthly quota**. When they run out, the app tells them to
  add their own key.

You only need the steps below to enable the **free tier** for the people you
share the app with. Without it, the app still works fully (analysis, EDHREC,
critique) and BYOK users still get AI.

Project: `mtgcollection-1add3`.

## One-time setup

1. **Firebase CLI + login:**
   ```bash
   npm install -g firebase-tools
   firebase login
   ```
   The repo already includes `.firebaserc` (pins the default project) and
   `firebase.json`, so run `firebase` commands from the repo root. Confirm with
   `firebase use`.

2. **Billing:** Cloud Functions require the **Blaze (pay-as-you-go)** plan.
   Upgrade `mtgcollection-1add3` in the Firebase console if it's still on Spark.

3. **Install deps and set the key secret:**
   ```bash
   cd functions && npm install && cd ..
   firebase functions:secrets:set ANTHROPIC_API_KEY
   ```

4. **Lock the usage counter (important).** The quota lives in Realtime Database
   at `ai_usage/<uid>`. The function writes it with the Admin SDK (which bypasses
   rules), but you must stop *clients* from resetting their own count. Add this
   to your RTDB security rules (Firebase console → Realtime Database → Rules):
   ```json
   {
     "rules": {
       "ai_usage": { ".read": false, ".write": false }
       // ... keep your existing rules for other paths ...
     }
   }
   ```

5. **Deploy:**
   ```bash
   firebase deploy --only functions
   ```
   The function is then at
   `https://us-central1-mtgcollection-1add3.cloudfunctions.net/deckAdvisor`
   (matches `FirebaseConfig.functionsBase`).

## Controlling cost (do this)

The per-user quota bounds *per person*, but not your total bill. Add a real cap:

- **Set a monthly spend limit on the Anthropic key** in the Anthropic console
  (Billing → limits) — this is the only *hard* stop. Recommended.
- Optionally set a **GCP budget alert** for the Firebase project.
- Tune the free allowance: the function reads `AI_MONTHLY_LIMIT` (default **20**
  reviews/user/month). Set it as a function env var or edit the constant in
  `functions/deck_advisor.js`.
- The free tier uses the cheaper **`claude-haiku-4-5`**; BYOK uses
  `claude-opus-5`. Change either in code if you want.

## How routing works in the app

- Has own key → direct Anthropic call (unlimited).
- No key, signed in → free tier via the function (quota-limited).
- No key, not signed in → the app asks them to sign in or add a key.
- Quota exhausted → the app shows the limit message and the 🔑 button to BYOK.
