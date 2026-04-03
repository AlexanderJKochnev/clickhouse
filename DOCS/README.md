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
3. items_seqarch_mv
актуальный макрос только там


0. Items:
   1. удалить индекс Index('idx_items_fts'...  ПОТОМ
   2. удалить search_vector в Search core model ПОТОМ
1. ALTER USER wine WITH REPLICATION;  #  выполнить в postgresql если пользователь не имеет прав на реплики 
## docker exec -it clickhouse_search clickhouse-client  # войти в clickhouse
# clickhouse
1. SET allow_experimental_database_materialized_postgresql = 1; 
2. создаем реплику см. ch_init.01_sync.sql
3. проверка данных 
SELECT count() FROM items_search

SELECT 
    (SELECT count() FROM wine_replica.items) AS in_replica,
    (SELECT count() FROM default.items_search) AS in_search_table;

   ┌─in_replica─┬─in_search_table─┐
1. │     210182 │          210182 │
   └────────────┴─────────────────┘

если нужно удалить таблицы перед пересозданием
DROP TABLE IF EXISTS default.items_search_mv;
DROP DATABASE IF EXISTS wine_replica;
DROP TABLE IF EXISTS default.items_search;
