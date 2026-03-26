-- 1. Подключаемся к Postgres (Внешняя таблица)
CREATE TABLE IF NOT EXISTS remote_items_stream (
    id Int32,
    search_content String
) ENGINE = PostgreSQL('wine_host:5432', 'wine_db', 'items', 'wine', 'wine1');

-- 2. Локальная таблица для быстрого поиска
-- Используем Inverted индекс для ускорения полнотекстового поиска
CREATE TABLE IF NOT EXISTS local_items (
    id Int32,
    search_content String,
    updated_at DateTime DEFAULT now(),
    -- Индекс для быстрого поиска по словам (аналог GIN в Postgres)
    INDEX inv_idx search_content TYPE inverted(0) GRANULARITY 1
) ENGINE = MergeTree()
ORDER BY id;

CREATE DATABASE IF NOT EXISTS wine_replica
ENGINE = MaterializedPostgreSQL(
    'wine_host:5432',
    'wine_db',
    'wine',
    'wine1'
)
SETTINGS
    materialized_postgresql_tables_list = 'items',
    materialized_postgresql_allow_automatic_update = 1
    TABLE OVERRIDE items (
    COLUMNS (
        id Int32,
        search_content String
    )
);