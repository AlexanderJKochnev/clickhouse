CREATE TABLE wine_replica.items
   │↳(                                     ↴│
   │↳    `id` Int32,                       ↴│
   │↳    `search_content` Nullable(String),↴│
   │↳    `_sign` Int8 MATERIALIZED 1,      ↴│
   │↳    `_version` UInt64 MATERIALIZED 1  ↴│
   │↳)                                     ↴│
   │↳ENGINE = ReplacingMergeTree(_version) ↴│
   │↳ORDER BY tuple(id) 

CREATE TABLE default.items_search                                                                                                  ↴│
   │↳(                                                                                                                                  ↴│
   │↳    `id` Int32,                                                                                                                    ↴│
   │↳    `search_content` String,                                                                                                       ↴│
   │↳    `_sign` Int8 DEFAULT 1,                                                                                                        ↴│
   │↳    `_version` UInt64,                                                                                                             ↴│
   │↳    INDEX inv_idx search_content TYPE text(tokenizer = splitByNonAlpha, preprocessor = lower(search_content)) GRANULARITY 100000000↴│
   │↳)                                                                                                                                  ↴│
   │↳ENGINE = ReplacingMergeTree(_version)                                                                                              ↴│
   │↳ORDER BY id                                                                                                                        ↴│
   │↳SETTINGS index_granularity = 8192       

CREATE MATERIALIZED VIEW default.items_search_mv TO default.items_search↴│
   │↳(                                                                       ↴│
   │↳    `id` Int32,                                                         ↴│
   │↳    `search_content` Nullable(String),                                  ↴│
   │↳    `_sign` Int8,                                                       ↴│
   │↳    `_version` UInt64                                                   ↴│
   │↳)                                                                       ↴│
   │↳AS SELECT                                                               ↴│
   │↳    id,                                                                 ↴│
   │↳    search_content,                                                     ↴│
   │↳    _sign,                                                              ↴│
   │↳    _version                                                            ↴│
   │↳FROM wine_replica.items                                                  │
   └──────────────────────────────────────────────────────────────────────────┘