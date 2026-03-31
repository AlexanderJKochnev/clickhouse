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

CREATE TABLE items_search (
    id Int32,
    search_content String,
    INDEX inv_idx search_content TYPE text(tokenizer = splitByNonAlpha, preprocessor = lower(search_content))
) ENGINE = ReplacingMergeTree()
ORDER BY id;

CREATE MATERIALIZED VIEW items_search_mv TO items_search AS
SELECT id, search_content FROM wine_replica.items;

INSERT INTO items_search SELECT id, search_content FROM wine_replica.items;
