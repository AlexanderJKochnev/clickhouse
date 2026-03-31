-- 1. Создаем базу данных, которая напрямую смотрит в Postgres
-- Это позволит нам делать SELECT прямо из таблиц Postgres через ClickHouse
CREATE DATABASE postgres_db
ENGINE = PostgreSQL('wine_host:5432', 'wine_db', 'wine', 'wine1');

-- 2. Создаем локальную таблицу в ClickHouse для полнотекстового поиска
-- Мы будем копировать туда данные для максимальной скорости
CREATE TABLE IF NOT EXISTS search_items (
    id Int32,
    search_content String,
    -- ClickHouse сам построит индекс при поиске, но для RAG мы добавим векторизацию позже
) ENGINE = MergeTree()
ORDER BY id;