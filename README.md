# clickhouse
clickhouse_repo

0. Items:
   1. удалить индекс Index('idx_items_fts'...
   2. удалить search_vector в Search core model
1. ALTER USER wine_user WITH REPLICATION;  #  выполнить в postgresql если пользователь не имеет прав на реплики
2. docker exec -it clickhouse_search clickhouse-client  # войти в clickhouse
3. проверка наличия таблиц 
    SHOW DATABASES; -- Должна появиться wine_replica
    USE wine_replica;
    с    -- Должна появиться таблица items
4. если не повилась: п.2 и вот это: 
CREATE DATABASE wine_replica 
ENGINE = MaterializedPostgreSQL('wine_host:5432', 'wine_db', 'wine_user', 'password')
SETTINGS 
    materialized_postgresql_tables_list = 'items'
TABLE OVERRIDE items (
    COLUMNS (
        id Int32,
        search_content String
    )
);

6. проверяем наличие таблицы
USE wine_replica;
SHOW TABLES; 
SELECT count() FROM items;
если items не появилась - читай дальше

7. войти в postgresql 
    docker compose exec -it wine_host psql -U wine -d wine_db
8. проверка прав пользователя
    SELECT usename, userepl FROM pg_user WHERE usename = 'wine';  # t (true)
9. проверка таблицы
    \d items  # PRIMARY KEY
10. проверка режима логировния
     SHOW wal_level;  # logical
11. создаем представление items без fts index 
CREATE VIEW items_for_ch AS SELECT id, search_content FROM items;
12. переходим в clickhouse обратно
13. DROP DATABASE IF EXISTS wine_replica;  # delere older version
14. SET allow_experimental_database_materialized_postgresql = 1;  # включить экспериментальные функции
15. создаем базу данных
CREATE DATABASE wine_replica 
ENGINE = MaterializedPostgreSQL(
    'wine_host:5432', 
    'wine_db', 
    'wine', 
    'wine1'
)
SETTINGS 
    materialized_postgresql_tables_list = 'items'
;
16. проверка создния таблицы (wait 5-10 sec)
SHOW TABLES FROM wine_replica;

