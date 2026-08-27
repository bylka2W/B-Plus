================================================================================
  B+ Knowledge Web Engine  +  Knowledge Quality/Coverage Engine  (TF Stage 2)
================================================================================

Что это такое (обзор)
--------------------------------------------------------------------------------
Это НЕ обычная LLM-модель. Это гибрид:

    Веса  = рассуждение модели (weights, НЕ выкладываются в этот репозиторий)
    Таблица (memory/) = внешняя долговременная память — Knowledge Web
    Движок (engine/)  = механизм ретрива (retrieval) / поиска по таблице

То есть «модель» здесь = таблица знаний + движок поверх неё. Весовые файлы
(*.pt, checkpoints/) НЕ пушатся в репозиторий — они собираются/обучаются
локально и подключаются через `bplus model create`, который автоматически
привязывает готовую память (memory/) к модели.

Ключевой принцип проекта
--------------------------------------------------------------------------------
«Нам не нужно 100% рёбер. Нам нужно 100% покрытия ПРИМЕНИМЫХ знаний каждого
объекта — с доказательством (evidence) каждого VERIFIED-утверждения».

Каждое поле Knowledge Record имеет состояние:
    VERIFIED / DERIVED / UNKNOWN / NOT_APPLICABLE
— а не просто 0/1. Coverage — это доля объектов, у которых есть доказательство
для каждого применимого (имеющего источник в коде) знания = 100%.

Стек (что лежит в папке agent)
--------------------------------------------------------------------------------
  memory/                 — ГОТОВАЯ таблица знаний (релизный артефакт,
                            скачивается через GitHub release). Содержит:
      source_symbols.json      9,235 символов из 401 файла исходников Zig
      source_evidence.json     9,151 запись доказательств (evidence)
      concepts.json            9,636 концепций
      semantic_relations.json  31,730 семантических связей (9,636 концепций)
      facts.json               26,910 фактов
      graph.json               граф знаний (9,636 узлов, 31,730 рёбер)
      source_index.json        индекс 401 исходного файла
      structured.json          собранное структурированное знание
      golden/                  контракты (incremental, performance, query…)

  agent b+/                 — основной движок Knowledge Web (TF Stage 2):
      core/knowledge_web.py   построение графа, evidence, метрики качества
      core/symbol_graph.py    AST -> SymbolGraph (символы, типы, колл-граф)
      core/query_engine.py    Query Engine
      core/agent_runtime.py   SourceIndex, KnowledgeQuery
      core/state_tables.py    детерминированные id (short_id = <PREFIX>-<sha16>)
      (тесты: test_symbol_graph_locations / test_step2_evidence /
       test_step3_types / test_query_engine_v2 / test_knowledge_web)

  engine/                 — движок ретрива: query, search, facts, concepts,
                            relations, evidence_verifier, graph_traversal,
                            entity_resolver, source_evidencidence, верcионирование.

  tests/                  — шлюзы качества (gate_*, bench_*, test_*).
  training/               — (строитель датасета / обучение; заморожено до
                            достижения целевой плотности знаний).

Текущие метрики Knowledge Web (живой граф)
--------------------------------------------------------------------------------
  Узлов:           21,166
  Рёбер:           106,333       (все `uses/used_by`, `calls/called_by`,
                                  `depends_on`, `returns`, `references`
                                  — двунаправленно консистентны, 0 висячих)
  DENSITY:         59.0%         (было 38.0%)
  fully-VERIFIED L10: 44.2%      (было 17.5%)
  reverse-consistency: 0 сбоев   (calls<->called_by, uses<->used_by)
  dangling edges:  0

  Покрытие по фазам (coverage coefficients):
      type 89.4%   structure 80.5%   relation 60.5%   dependency 47.7%
      callgraph 33.3%   semantic 55.2%   evidence 80.5%   crossreference 55.2%

Проверенные фазы (TF order: Correctness -> Provenance -> Coverage -> Closure)
--------------------------------------------------------------------------------
  PHASE 0/1  AST -> SymbolGraph locations      ЗАКРЫТА (test 3/3)
  PHASE 2    Evidence (100% применимых)        ЗАКРЫТА (test 3/3)
  PHASE 3    Type (9,451 type-relations)       ЗАКРЫТА (test 3/3)
  PHASE 4    Dependency (depends_on + used_by) В ПРОЦЕССЕ (43.5% -> 47.7%)
  PHASE 5    Callgraph (calls <-> called_by)   В ПРОЦЕССЕ (двунаправленно OK)
  PHASE 11   Canonical Entity                  ЗАКРЫТА

Как запросить модель (как задать вопрос агенту)
--------------------------------------------------------------------------------
Движок ретрива отвечает, комбинируя ПАМЯТЬ (таблица) + РАССУЖДЕНИЕ модели
(weights). Запрос — это вопрос на естественном языке или по символу/файлу:

  Примеры запросов:
    «Как называется тип, который возвращает функция X?»
    «Какие функции вызывают Y?»
    «Покажи распечатку (trace/дамп) узла Z: символ, тип, evidence, зависимости»
    «Какое доказательство (evidence_id, строка, файл, hash) у VERIFIED-факта F?»

Правила ответа (анти-галлюцинация):
  - Каждый VERIFIED факт обязан иметь evidence_id, указывающий на реальный
    исходник (.zig): {id, source_file, file_id, sha256, line_start, line_end,
    text, verification_status}.
  - Изменение/удаление исходника инвалидирует VERIFIED (evidence re-verify).
  - Детерминированные id: short_id(prefix, *parts) = <PREFIX>-<sha16hex>.
  - Не выдумываем факты; UNKNOWN/NOT_APPLICABLE — честный ответ.

Как запустить проверки (regression gate)
--------------------------------------------------------------------------------
  python "agent b+/core/test_symbol_graph_locations.py"
  python "agent b+/core/test_step2_evidence.py"
  python "agent b+/core/test_step3_types.py"
  python "agent b+/core/test_query_engine_v2.py"
  python "agent b+/core/test_knowledge_web.py"
(или все 5 суит — «полный шлюз»; на RTX 5060 Ti 16GB ~ минуты)

Релиз памяти (GitHub release)
--------------------------------------------------------------------------------
Пользователь НЕ сканирует B+/Zig и НЕ строит web сам. Вместо этого:
  1) Мы собираем и ВЕРИФИЦИРУЕМ память здесь (memory/).
  2) Упаковываем memory/ как релизный артефакт (manifest.json).
  3) Пользователь скачивает prebuilt memory через GitHub release.
  4) `bplus model create` авто-подключает её к модели.

Дорожная карта (далее)
--------------------------------------------------------------------------------
  PHASE 5  Callgraph  ->  PHASE 6 Cross-reference -> PHASE 7 Structure ->
  PHASE 8  Relations  ->  PHASE 9 Tests -> PHASE 10 Semantic ->
  PHASE 11 Closure -> PHASE 12 KCS -> PHASE 13 Compact Context ->
  PHASE 14 Search -> PHASE 15 Query -> PHASE 16 Verify candidates ->
  PHASE 17 Integrity Gate (releaseable) -> PHASE 18 сборка memory release.

ВАЖНО: Веса модели (*.pt, checkpoints/) НЕ пушатся в репозиторий.
Этот репозиторий содержит двигатель + таблицу знаний (память), но не веса.
