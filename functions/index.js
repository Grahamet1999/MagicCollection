const admin = require("firebase-admin");

admin.initializeApp();

// The shared-tier AI deck advisor — see deck_advisor.js.
exports.deckAdvisor = require("./deck_advisor").deckAdvisor;
