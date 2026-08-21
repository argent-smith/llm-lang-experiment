// Явный конфиг для внешней code quality-проверки JS/TS-пилота
// (scripts/run-code-quality.sh) — не конфиг самого пилотного проекта,
// пилотный агент этот файл не видит.
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

import js from "@eslint/js";
import sonarjs from "eslint-plugin-sonarjs";
import tseslint from "typescript-eslint";

export default tseslint.config(
  js.configs.recommended,
  tseslint.configs.recommended,
  sonarjs.configs.recommended,
  {
    files: ["**/*.js", "**/*.mjs", "**/*.cjs"],
    ...tseslint.configs.disableTypeChecked,
  },
);
