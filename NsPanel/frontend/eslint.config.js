// Flat config: Vue + TypeScript recommended rules, accessibility checks for
// templates, and Prettier last so formatting is never a lint error.
import pluginVue from 'eslint-plugin-vue';
import pluginA11y from 'eslint-plugin-vuejs-accessibility';
import { defineConfigWithVueTs, vueTsConfigs } from '@vue/eslint-config-typescript';
import skipFormatting from '@vue/eslint-config-prettier/skip-formatting';

export default defineConfigWithVueTs(
  { ignores: ['node_modules/**', '../static/dist/**', 'dist/**'] },
  pluginVue.configs['flat/recommended'],
  vueTsConfigs.recommended,
  pluginA11y.configs['flat/recommended'],
  {
    files: ['**/*.{ts,vue}'],
    rules: {
      // Single-word names like Btn, Tabs, Field are the design-system vocabulary.
      'vue/multi-word-component-names': 'off',
      '@typescript-eslint/no-unused-vars': ['error', { argsIgnorePattern: '^_', varsIgnorePattern: '^_' }],
      // Labels are wired through the shared Field component (for/id via slot props).
      'vuejs-accessibility/label-has-for': 'off',
    },
  },
  skipFormatting,
);
