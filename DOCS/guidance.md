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

# переименование таблицы
RENAME TABLE старое_имя TO новое_имя;

# копирование схемы таблицы
-- Создаст только структуру со всеми индексами, но без данных
CREATE TABLE beverages_rag_v2 AS beverages_rag EMPTY;

# поменять местами названия у двух таблиц
RENAME TABLE beverages_rag TO table_temp, beverages_rag_v2 TO beverages_rag, table_temp TO beverages_rag_v2;

# клонирование нескольких таблиц из postgresql
SET allow_experimental_database_materialized_postgresql = 1;
CREATE DATABASE wine_replica
ENGINE = MaterializedPostgreSQL(
    'wine_host:5432',
    'wine_db',
    'wine',
    'wine1'
)
SETTINGS
    materialized_postgresql_tables_list = 'items(id, drink_id, word_hashes), drinks(id, title, display_name, lwin, subcategory_id), subcategories(id, name, category_id), categories(id, name)'; 
# посмотреть описание таблиц
DESCRIBE TABLE wine_replica.items;
DESCRIBE TABLE wine_replica.drinks;

# создание таблицы (обычной)
CREATE TABLE default.items_target (
    id Int32,
    drink_id Int32,
    title String,
    lwin Nullable(String), 
    display_name Nullable(String),
    category Nullable(String),
    category_id Int32,
    subcategory Nullable(String),
    subcategory_id Int32,
    word_hashes Array(UInt64),
    _sign Int8 DEFAULT 1,
    _version UInt64
) ENGINE = MergeTree()
ORDER BY (lwin, length(word_hashes), id)
SETTINGS allow_nullable_key = 1;  -- разрешаем Nullable в ключе сортировки

# заполнение таблицы первичное
-- Вставляем все существующие данные
INSERT INTO default.items_target
SELECT 
    i.id,
    i.drink_id,
    d.title,
    d.lwin,
    d.display_name,
    c.name,
    c.id,
    s.name,
    s.id,
    i.word_hashes,
    i._sign,
    i._version
FROM wine_replica.items i
JOIN wine_replica.drinks d ON i.drink_id = d.id
JOIN wine_replica.subcategories s on d.subcategory_id = s.id
JOIN wine_replica.categories c on s.category_id = c.id
WHERE i._sign = 1 AND d._sign = 1;

# проверка целостности 
SELECT 
    (SELECT count() FROM wine_replica.items) as items_source,
    (SELECT count() FROM wine_replica.drinks) as drinks_source,
    (SELECT count() FROM default.items_target) as items_target;

SELECT 
    id,
    drink_id,
    title,
    lwin,
    length(word_hashes) as words_count
FROM items_target
ORDER BY _version DESC
LIMIT 10;

# запрос на сопоставление 1 записи
WITH group1 AS (
    SELECT id, title, word_hashes, subcategory_id, category_id, category, subcategory
    FROM default.items_target
    WHERE lwin IS NULL AND id = 124
),
group2 AS (
    SELECT id, lwin, display_name, word_hashes, subcategory_id, category_id, category, subcategory
    FROM default.items_target
    WHERE lwin IS NOT NULL
)
SELECT 
    g1.id AS id_no_lwin,
    g1.title AS title_no_lwin,
    g2.id AS id_with_lwin,
    g2.display_name AS display_name_with_lwin,
    g2.lwin,
    round(length(arrayIntersect(g1.word_hashes, g2.word_hashes)) / length(g2.word_hashes), 4) AS similarity
FROM group1 g1
CROSS JOIN group2 g2
WHERE hasAny(g1.word_hashes, g2.word_hashes)
    AND length(arrayIntersect(g1.word_hashes, g2.word_hashes)) / length(g2.word_hashes) >= 0.3
    AND g1.category_id = g2.category_id
ORDER BY g1.id, similarity DESC;

# matching
WITH 
group1 AS (
    SELECT 
        id, 
        title, 
        word_hashes,
        category_id,
        subcategory_id
    FROM default.items_target
    WHERE lwin IS NULL
),
group2 AS (
    SELECT 
        id, 
        lwin, 
        display_name, 
        word_hashes,
        category_id,
        subcategory_id
    FROM default.items_target
    WHERE lwin IS NOT NULL
),
similarity_calc AS (
    SELECT 
        g1.title,
        g2.display_name,
        g1.id AS drink_id_no_lwin,
        g2.id AS drink_id_with_lwin,
        g2.lwin AS lwin_value,
        round(length(arrayIntersect(g1.word_hashes, g2.word_hashes)) / length(g2.word_hashes), 4) AS similarity,
        row_number() OVER (PARTITION BY g1.id ORDER BY similarity DESC) AS rn
    FROM group1 g1
    CROSS JOIN group2 g2
    WHERE g1.subcategory_id = g2.subcategory_id
        AND hasAny(g1.word_hashes, g2.word_hashes)
        AND length(arrayIntersect(g1.word_hashes, g2.word_hashes)) / length(g2.word_hashes) >= 0.3
)
SELECT 
    title,
    display_name,
    drink_id_no_lwin,
    -- drink_id_with_lwin,
    lwin_value,
    similarity
FROM similarity_calc
WHERE rn = 1
ORDER BY similarity DESC;

# таблица для результатов
CREATE TABLE default.lwin_matches (
    drink_id_no_lwin Int32,
    drink_id_with_lwin Int32,
    lwin_value String,
    similarity Float32,
    matched_at DateTime DEFAULT now()
) ENGINE = MergeTree()
ORDER BY (similarity, drink_id_no_lwin);
# заполнение таблицы (проверить)
INSERT INTO default.lwin_matches (drink_id_no_lwin, drink_id_with_lwin, lwin_value, similarity)
WITH 
group1 AS (
    SELECT id, word_hashes, category_id
    FROM default.items_target
    WHERE lwin = ''
),
group2 AS (
    SELECT id, lwin, word_hashes, category_id
    FROM default.items_target
    WHERE lwin != ''
),
similarity_calc AS (
    SELECT 
        g1.id AS drink_id_no_lwin,
        g2.id AS drink_id_with_lwin,
        g2.lwin AS lwin_value,
        round(length(arrayIntersect(g1.word_hashes, g2.word_hashes)) / length(g2.word_hashes), 4) AS similarity,
        row_number() OVER (PARTITION BY g1.id ORDER BY similarity DESC) AS rn
    FROM group1 g1
    CROSS JOIN group2 g2
    WHERE g1.category_id = g2.category_id
        AND hasAny(g1.word_hashes, g2.word_hashes)
        AND length(arrayIntersect(g1.word_hashes, g2.word_hashes)) / length(g2.word_hashes) >= 0.3
)
SELECT 
    drink_id_no_lwin,
    drink_id_with_lwin,
    lwin_value,
    similarity
FROM similarity_calc
WHERE rn = 1;

# -- Расчет similarity для конкретной пары (id_no_lwin, id_with_lwin)
WITH 
item1 AS (
    SELECT word_hashes
    FROM default.items_target
    WHERE id = 124
    LIMIT 1
),
item2 AS (
    SELECT word_hashes
    FROM default.items_target
    WHERE id = 456
    LIMIT 1
)
SELECT 
    124 AS id_no_lwin,
    456 AS id_with_lwin,
    round(
        length(arrayIntersect(
            (SELECT word_hashes FROM item1), 
            (SELECT word_hashes FROM item2)
        )) / length((SELECT word_hashes FROM item2)), 
        4
    ) AS similarity;