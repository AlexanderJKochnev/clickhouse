## руководство по ручному созданию 
# вход в контейнер
docker exec -it clickhouse_search clickhouse-client

# проверка что там уже есть
SHOW DATABASES;
USE wine_replica;
# если нет - создать
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
#  проверка
SHOW TABLE wine_replica.items
SELECT count() FROM  wine_replica.items;
# сверить с количеством записей в POSTGRESQL. заодно узнать к какой базе он присосался (с текущими настройками к test)
docker exec -i test-wine_host-1 psql -U wine -d wine_db -c "SELECT id FROM items;"

# создаем следующую таблицу

DROP TABLE IF EXISTS items_search;
DROP TABLE IF EXISTS items_search_mv;
CREATE TABLE default.items_search (
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
#  создание триггера по обновлению items_default
SET allow_experimental_refreshable_materialized_view = 1;
CREATE MATERIALIZED VIEW default.items_search_mv 
REFRESH EVERY 1 MINUTE TO default.items_search
AS
SELECT
    id,
    search_content,
    _sign,
    _version
FROM wine_replica.items;


#  проверка (0)
SELECT count() FROM default.items_search;

# добавление записей первоначальное
INSERT INTO default.items_search
SELECT
    id,
    search_content,
    _sign,
    _version
FROM wine_replica.items
WHERE _sign = 1;

#  проверка (соотвествует кол-ву в pg)
SELECT count() FROM default.items_search;

