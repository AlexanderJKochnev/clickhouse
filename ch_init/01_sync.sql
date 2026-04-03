-- 1. Создаем базу данных, которая напрямую смотрит в Postgres
-- Это позволит нам делать SELECT прямо из таблиц Postgres через ClickHouse
SET allow_experimental_database_materialized_postgresql = 1;

CREATE DATABASE wine_replica
ENGINE = MaterializedPostgreSQL(
    'wine_host:5432',
    'wine_db',
    'wine',
    'wine1'
)
SETTINGS
    materialized_postgresql_tables_list = 'items(id, search_content)';

DROP TABLE IF EXISTS items_search;
DROP TABLE IF EXISTS items_search_mv;

-- Создаем таблицу с ReplacingMergeTree для отслеживания версий
CREATE TABLE items_search (
    id Int32,
    search_content String,
    _sign Int8 DEFAULT 1,
    _version UInt64,
    INDEX inv_idx search_content TYPE text(
        tokenizer = splitByNonAlpha,
        preprocessor = lower(search_content)
    )
) ENGINE = ReplacingMergeTree(_version)
ORDER BY id;

CREATE MATERIALIZED VIEW items_search_mv TO items_search AS
SELECT
    id,
    search_content,
    _sign,
    _version
FROM wine_replica.items;

-- Вставляем ТОЛЬКО актуальные записи из реплики
INSERT INTO items_search
SELECT
    id,
    search_content,
    _sign,
    _version
FROM wine_replica.items
WHERE _sign = 1;