// Явный конфиг для внешней code quality-проверки JavaScript-пилота
// (scripts/run-code-quality.sh) — не конфиг самого пилотного проекта,
// пилотный агент этот файл не видит. Сестринский конфиг —
// scripts/code-quality-configs/typescript/eslint.config.js — держит
// то же самое плюс typescript-eslint; здесь его нет намеренно: чистый
// JavaScript-проект не тянет TypeScript-тулинг, как и не тянул бы его
// в реальной практике (см. CLAUDE.md, «Языки доклада» — JavaScript и
// TypeScript разделены на два самостоятельных пилота).
//
// @eslint/js recommended — конвенциональная стартовая точка 2026 года
// (flat config, ESLint 9+) для JS-проекта без TypeScript: тот же набор,
// что и в typescript/eslint.config.js, минус typescript-eslint.
//
// eslint-plugin-sonarjs (recommended) добавлен отдельно: архитектурные/
// структурные code smell (cognitive complexity, дублирование и т. п.)
// в область этой проверки сознательно включены — тем же принципом,
// что и для остальных языков (см. CLAUDE.md, раздел «Метод»).
//
// Security-ориентированный eslint-plugin-security сюда намеренно не
// включён: code security исключён из метода отдельным решением (см.
// docs/PILOT-COMPARISON-python-go.md, «Code security (исключено)»).
//
// languageOptions.globals: globals.node — без него flat config ESLint
// 9+ не знает Node.js-окружения вообще (в отличие от старого .eslintrc
// с `env: node`) и бьёт no-undef на `require`/`process`/`module` и т.п.
// в любом обычном Node-коде — не находка о качестве пилотного кода, а
// дыра в этом конфиге. Обнаружено эмпирически на первом же реальном
// прогоне (JavaScript, тикет 1, 2026-08-26): 24 из 36 findings были
// `no-undef` на стандартных Node-глобалах.

import js from "@eslint/js";
import sonarjs from "eslint-plugin-sonarjs";
import globals from "globals";

export default [
  js.configs.recommended,
  sonarjs.configs.recommended,
  {
    languageOptions: {
      globals: globals.node,
    },
  },
];
