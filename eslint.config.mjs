// Lints the JavaScript the skills ship. Repo tooling only: skills are
// installed per folder, so nothing here reaches anyone's deck or dashboard.
import js from '@eslint/js';
import globals from 'globals';

export default [
  { ignores: ['**/node_modules/**'] },

  js.configs.recommended,

  {
    rules: {
      // `_`-prefixed names are deliberately unused (callback positions)
      'no-unused-vars': ['error', { argsIgnorePattern: '^_', varsIgnorePattern: '^_' }],
    },
  },

  // interactive-reveal-deck: classic <script> files sharing globals, loaded
  // in a fixed order by index.html -- not modules.
  {
    files: ['skills/interactive-reveal-deck/assets/js/**/*.js'],
    languageOptions: {
      sourceType: 'script',
      globals: {
        ...globals.browser,
        Reveal: 'readonly',
        DeckCode: 'readonly',
        DeckWidgets: 'readonly',
        DeckChrome: 'readonly',
      },
    },
  },

  // ha-wall-dashboard: browser ES modules on the tablet...
  {
    files: ['skills/ha-wall-dashboard/assets/starter/**/*.js'],
    languageOptions: { sourceType: 'module', globals: globals.browser },
  },
  // ...and Node scripts and tests around them.
  {
    files: ['skills/**/*.mjs'],
    languageOptions: { sourceType: 'module', globals: globals.node },
  },
];
