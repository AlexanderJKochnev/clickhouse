# материализованная таблица из postgresql
CREATE DATABASE test_replica
ENGINE = MaterializedPostgreSQL(
    'wine_host:5432',
    'test_db',
    'wine',
    'wine1'
)
SETTINGS
    materialized_postgresql_tables_list = 'wordhashs(id, word, freq, mainword_id), mainwords(id, word)'; 

# view

CREATE VIEW default.beverages_words_active (`word` String, `freq` UInt32, `hash` Int64,)
AS
SELECT bw.word, bw.freq, bw.hash FROM default.beverages_words bw
LEFT OUTER JOIN test_replica.wordhashs tw ON bw.word = tw.word
WHERE tw.id == 0;

SELECT count() FROM default.beverages_words bw
LEFT OUTER JOIN test_replica.wordhashs tw ON bw.word = tw.word
WHERE tw.id == 0;

## drinks
SET allow_experimental_database_materialized_postgresql = 1;

CREATE DATABASE drink_replica
ENGINE = MaterializedPostgreSQL(
        'wine_host:5432',
        'wine_db',
        'wine',
        'wine1'
)
SETTINGS
    materialized_postgresql_tables_list = 'drinks, subcategories';


CREATE VIEW default.drink_origin (`id` Int32, `title` String, `subtitle` Nullable(String))
AS
SELECT bw.id, bw.title, bw.subtitle 
FROM drink_replica.drinks bw
WHERE bw.lwin IS NULL;

CREATE VIEW default.lwins (`id` Int32, `lwin` String, `display_name` Nullable(String))
AS
SELECT bw.id, bw.lwin, bw.display_name 
FROM drink_replica.drinks bw
WHERE bw.lwin IS NOT NULL;
-----ORIGIN - LWINS ---------
SELECT 
    d.id,
    d.full_name AS drink_name,
    l.display_name AS lwin_name,
    l.lwin,
    -- Вычисляем дистанцию (0 - идентичны, 1 - совсем разные)
    ngramDistance(d.full_name, l.display_name) AS distance
FROM (
    SELECT id, concat(title, ' ', subtitle) AS full_name 
    FROM drink_origin
) AS d
CROSS JOIN lwins AS l
-- Фильтруем, чтобы оставить только достаточно похожие (например, индекс < 0.4)
WHERE distance < 0.45 
ORDER BY id, distance ASC
-- Опционально: оставить только 1 лучший результат для каждого напитка
LIMIT 1 BY id

-----ORIGIN - BIG DATA-----------
SELECT 
    d.id,
    d.full_name AS drink_name,
    l.name AS lwin_name,
    l.id AS lwin_id,
    -- Вычисляем дистанцию (0 - идентичны, 1 - совсем разные)
    ngramDistance(d.full_name, l.name) AS distance
FROM (
    SELECT id, concat(title, ' ', subtitle) AS full_name 
    FROM drink_origin
) AS d
CROSS JOIN beverages_indexed AS l
-- Фильтруем, чтобы оставить только достаточно похожие (например, индекс < 0.4)
WHERE distance < 0.45 
ORDER BY id, distance ASC
-- Опционально: оставить только 1 лучший результат для каждого напитка
LIMIT 1 BY id
-----LWIN - BIG DATA ---------

CREATE TABLE default.drinks = MergeTree ORDER BY norm_name AS
SELECT 
    *,
    -- Нижний регистр, удаление спецсимволов, замена 'chateau' на 'ch' (синонимы)
    lower(regexpReplaceAll(display_name, '[^a-zA-Z0-9 ]', '')) as norm_name
FROM lwins;