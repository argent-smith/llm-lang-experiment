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

import js from "@eslint/js";
import sonarjs from "eslint-plugin-sonarjs";

export default [
  js.configs.recommended,
  sonarjs.configs.recommended,
];
