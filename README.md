# clickhouse
## схема
### Postgres -> (WAL репликация) -> wine_replica.items (в ClickHouse).
### wine_replica.items -> (Внутренний MV) -> items_search (с индексом).
SHOW DATABASES;
USE <DATABASE NAME>;
SHOW TABLES;
DESCRIBE wine_replica.items;

см. ch_init.01_sync.sql: этот макрос должен при первом запуске создать 
1. wine_replica.items
2. items_search (с индексом)


0. Items:
   1. удалить индекс Index('idx_items_fts'...  ПОТОМ
   2. удалить search_vector в Search core model ПОТОМ
1. ALTER USER wine WITH REPLICATION;  #  выполнить в postgresql если пользователь не имеет прав на реплики 
## docker exec -it clickhouse_search clickhouse-client  # войти в clickhouse
# clickhouse
1. SET allow_experimental_database_materialized_postgresql = 1; 
2. создаем реплику
CREATE DATABASE wine_replica 
ENGINE = MaterializedPostgreSQL(
    'wine_host:5432', 
    'wine_db', 
    'wine', 
    'wine1'
)
SETTINGS 
    materialized_postgresql_tables_list = 'items(id, search_content)';


4. SHOW TABLES FROM wine_replica;
-- Если таблица появилась, проверяем структуру
DESCRIBE wine_replica.items;

5. таблица для поиска
CREATE TABLE items_search (
    id Int32,
    search_content String,
    INDEX inv_idx search_content TYPE text(tokenizer = splitByNonAlpha, preprocessor = lower(search_content))
) ENGINE = ReplacingMergeTree()
ORDER BY id;

6. Создаем триггер (Materialized View) для автозаполнения:
CREATE MATERIALIZED VIEW items_search_mv TO items_search AS 
SELECT id, search_content FROM wine_replica.items;

7. Разовая «доливка» существующих данных:
INSERT INTO items_search SELECT id, search_content FROM wine_replica.items;

8. проверка данных 
SELECT count() FROM items_search

SELECT 
    (SELECT count() FROM wine_replica.items) AS in_replica,
    (SELECT count() FROM default.items_search) AS in_search_table;

   ┌─in_replica─┬─in_search_table─┐
1. │     210182 │          210182 │
   └────────────┴─────────────────┘

DROP TABLE IF EXISTS default.items_search_mv;
DROP DATABASE wine_replica;
DROP TABLE default.items_search;

------------------------
## ШАГ 3: Проверка поиска и Ранжирования
SELECT id
FROM default.items_search
WHERE hasToken(search_content, 'hennessy') 
   AND hasToken(search_content, 'brill')
ORDER BY id
LIMIT 10;

SELECT id, search_content
FROM default.items_search
WHERE multiSearchAny(lower(search_content), ['hennessy']) 
  AND multiSearchAny(lower(search_content), ['brill'])
  AND multiSearchAny(lower(search_content), ['prive'])
LIMIT 5;

# POSTGRESQL
1. add to requirements.txt  asynch