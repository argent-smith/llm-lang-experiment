// Явный конфиг для внешней code quality-проверки TypeScript-пилота
// (scripts/run-code-quality.sh) — не конфиг самого пилотного проекта,
// пилотный агент этот файл не видит. Изначально общий для JS/TS,
// разделён на javascript/ и typescript/ при разделении языка доклада
// на два отдельных пилота (JavaScript и TypeScript — см. CLAUDE.md,
// «Языки доклада») — этот файл сохраняет typescript-eslint, соседний
// scripts/code-quality-configs/javascript/eslint.config.js — нет.
//
// @eslint/js recommended + typescript-eslint recommended —
// конвенциональная стартовая точка 2026 года (flat config, ESLint 9+):
// подтверждена независимо несколькими текущими источниками, не
// выбрана произвольно — см. коммит, добавивший этот файл.
// tseslint.configs.recommended (не recommended-type-checked) — без
// проверок, требующих скомпилированный проект с tsconfig — внешний
// ассессор не должен зависеть от того, собирается ли пилотный проект.
//
// eslint-plugin-sonarjs (recommended) добавлен отдельно: архитектурные/
// структурные code smell (cognitive complexity, дублирование и т. п.)
// в область этой проверки сознательно включены.
//
// Security-ориентированный eslint-plugin-security сюда намеренно не
// включён: code security исключён из метода отдельным решением (см.
// docs/PILOT-COMPARISON-python-go.md, «Code security (исключено)»).
//
// languageOptions.globals: globals.node — без него flat config ESLint
// 9+ не знает Node.js-окружения вообще (в отличие от старого .eslintrc
// с `env: node`) и бьёт no-undef на `process`/`require`/`module` и
// т.п. в любом обычном Node-коде — не находка о качестве пилотного
// кода, а дыра в конфиге. Найдено на сестринском javascript/ (тикет 1,
// 2026-08-26: 24 из 36 findings были `no-undef` на Node-глобалах) и
// исправлено здесь заранее, до первого прогона TypeScript-пилота.

import js from "@eslint/js";
import sonarjs from "eslint-plugin-sonarjs";
import tseslint from "typescript-eslint";
import globals from "globals";

export default tseslint.config(
  js.configs.recommended,
  tseslint.configs.recommended,
  sonarjs.configs.recommended,
  {
    files: ["**/*.js", "**/*.mjs", "**/*.cjs"],
    ...tseslint.configs.disableTypeChecked,
  },
  {
    languageOptions: {
      globals: globals.node,
    },
  },
);
