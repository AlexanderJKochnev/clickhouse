# beer_raw

## Создание нового справочника и расширение pg_drink
-- 1. Создаем справочник типов пива (Many-to-One)
CREATE TABLE default.pg_beer_type (id UInt32, name String) ENGINE = MergeTree() ORDER BY id;

-- 2. Расширяем главную таблицу внешним ключом для типа пива
ALTER TABLE default.pg_drink ADD COLUMN beer_type_id Nullable(UInt32);

## Анализ и инкрементальное наполнение категорий (Пиво)
DROP TABLE IF EXISTS default.tmp_beer_categories;

CREATE TABLE default.tmp_beer_categories ENGINE = MergeTree() ORDER BY token AS
WITH
    splitByChar(',', lower(coalesce(Categories, ''))) AS tokens_arr
SELECT
    trimBoth(token) AS token,
    coalesce(Categories, '') AS original_string,
    -- Проверяем пересечения с базовым винным/крепким алкоголем
    CASE
        WHEN position(token, 'sparkling') > 0 THEN 6
        WHEN position(token, 'red') > 0 THEN 4
        WHEN position(token, 'white') > 0 THEN 7
        ELSE NULL
    END AS matched_category_id
FROM default.beer_raw
LEFT ARRAY JOIN tokens_arr AS token
WHERE token != '';

## Добавляем уникальные пивные категории в pg_category
INSERT INTO default.pg_category (id, name, synonyms, full_name)
WITH 
    strings_with_valid_category AS (
        SELECT DISTINCT original_string FROM default.tmp_beer_categories WHERE matched_category_id IS NOT NULL
    ),
    non_category_tokens AS (
        SELECT DISTINCT token FROM default.tmp_beer_categories 
        WHERE original_string IN strings_with_valid_category AND matched_category_id IS NULL
    ),
    (SELECT max(id) FROM default.pg_category) AS max_id
SELECT
    CAST(max_id + rowNumberInAllBlocks() + 1 AS UInt32) AS id,
    concat(upper(substr(src_tokens.token, 1, 1)), substr(src_tokens.token, 2)) AS name,
    [src_tokens.token] AS synonyms,
    src_tokens.token AS full_name
FROM (
    SELECT DISTINCT token FROM default.tmp_beer_categories
    WHERE matched_category_id IS NULL AND token NOT IN non_category_tokens
) AS src_tokens
LEFT JOIN default.pg_category AS existing ON src_tokens.token = lower(existing.name)
WHERE existing.name = '';

## Создаем точечный резолвер для пивных категорий:
DROP TABLE IF EXISTS default.join_beer_category_resolver;
CREATE TABLE default.join_beer_category_resolver (token String, id UInt32) ENGINE = Join(ANY, LEFT, token);

INSERT INTO default.join_beer_category_resolver
SELECT token, CAST(matched_category_id AS UInt32) FROM default.tmp_beer_categories WHERE matched_category_id IS NOT NULL GROUP BY token, matched_category_id;

INSERT INTO default.join_beer_category_resolver
SELECT arrayJoin(synonyms) AS token, id FROM default.pg_category WHERE id > 7;

## Наполнение нового справочника Type и расширение Many-to-Many (Food, Tasting Notes)
-- 1. Заполняем новый справочник типов пива (Many-to-One)
INSERT INTO default.pg_beer_type (id, name)
SELECT CAST(rowNumberInAllBlocks() + 1 AS UInt32), t
FROM (SELECT trimBoth(`Type`) AS t FROM default.beer_raw WHERE t IS NOT NULL AND t != '' GROUP BY t);

-- 2. Инкрементально дополняем вкусовые заметки (Tasting Notes)
INSERT INTO default.pg_tasting_note (id, name)
WITH (SELECT coalesce(max(id), 0) FROM default.pg_tasting_note) AS max_id
SELECT CAST(max_id + rowNumberInAllBlocks() + 1 AS UInt32), src.trimmed_t
FROM (
    SELECT trimBoth(t_item) AS trimmed_t FROM default.beer_raw
    LEFT ARRAY JOIN splitByChar(',', coalesce(`Tasting Notes`, '')) AS t_item
    WHERE trimmed_t != '' GROUP BY trimmed_t
) AS src
LEFT JOIN default.pg_tasting_note AS target ON src.trimmed_t = target.name WHERE target.name IS NULL;

-- 3. Инкрементально дополняем сочетания еды (Food Pairing)
INSERT INTO  (id, name)
WITH (SELECT coalesce(max(id), default.pg_food0) FROM default.pg_food) AS max_id
SELECT CAST(max_id + rowNumberInAllBlocks() + 1 AS UInt32), src.trimmed_f
FROM (
    SELECT trimBoth(f_item) AS trimmed_f FROM default.beer_raw
    LEFT ARRAY JOIN splitByChar(',', coalesce(`Food Pairing`, '')) AS f_item
    WHERE trimmed_f != '' GROUP BY trimmed_f
) AS src
LEFT JOIN default.pg_food AS target ON src.trimmed_f = target.name WHERE target.name IS NULL;

## Инкрементальное наполнение старых справочников (Страны и Бренды)
-- 1. Страны (с нормализацией США)
INSERT INTO default.pg_country (id, name)
WITH (SELECT coalesce(max(id), 0) FROM default.pg_country) AS max_id
SELECT CAST(max_id + rowNumberInAllBlocks() + 1 AS UInt32), src.c_name
FROM (
    SELECT CASE 
        WHEN trimBoth(Country) IN ('US', 'USA', 'United States', 'United States of America') THEN 'US'
        ELSE nullIf(trimBoth(Country), '')
    END AS c_name FROM default.beer_raw WHERE c_name IS NOT NULL GROUP BY c_name
) AS src
LEFT JOIN default.pg_country AS target ON src.c_name = target.name WHERE target.name IS NULL;

-- 2. Бренды (Winery / Brand)
INSERT INTO default.pg_winery (id, name)
WITH (SELECT coalesce(max(id), 0) FROM default.pg_winery) AS max_id
SELECT CAST(max_id + rowNumberInAllBlocks() + 1 AS UInt32), src.Brand
FROM (SELECT Brand FROM default.beer_raw WHERE Brand IS NOT NULL GROUP BY Brand) AS src
LEFT JOIN default.pg_winery AS target ON src.Brand = target.name WHERE target.name IS NULL;

## Наполнение главной таблицы pg_drink пивными данными
CREATE OR REPLACE VIEW default.v_beer_pre_insert AS
WITH (SELECT coalesce(max(id), 0) FROM default.pg_drink) AS max_id
SELECT 
    CAST(max_id + rowNumberInAllBlocks() + 1 AS UInt32) AS drink_id,
    Name AS wine,
    Brand AS winery,
    Description AS review,
    CASE 
        WHEN trimBoth(Country) IN ('US', 'USA', 'United States', 'United States of America') THEN 'US'
        ELSE nullIf(trimBoth(Country), '')
    END AS country_name,
    nullIf(trimBoth(`Type`), '') AS beer_type_name,
    `Food Pairing` AS food_raw,
    `Tasting Notes` AS tasting_raw,
    (
        SELECT min(joinGet('default.join_beer_category_resolver', 'id', trimBoth(token)))
        FROM (SELECT arrayJoin(splitByChar(',', lower(coalesce(Categories, '')))) AS token)
        WHERE joinGet('default.join_beer_category_resolver', 'id', trimBoth(token)) > 0
    ) AS resolved_category_id
FROM default.beer_raw;

## Заливаем данные в pg_drink
INSERT INTO default.pg_drink
SELECT
    d.drink_id AS id,
    d.wine,
    d.review,
    w.id AS winery_id,
    NULL AS designation_id,
    nullIf(d.resolved_category_id, 0) AS category_id,
    NULL AS site_id,
    NULL AS subregion_id,
    NULL AS region_id,
    c.id AS country_id,
    NULL AS serving_temp,
    NULL AS glassware_id,
    NULL AS scale_id,
    NULL AS body_id,
    NULL AS abv,
    NULL AS years_aged,
    bt.id AS beer_type_id -- Подтягиваем ID типа пива
FROM default.v_beer_pre_insert AS d
LEFT JOIN default.pg_winery AS w ON d.winery = w.name
LEFT JOIN default.pg_country AS c ON d.country_name = c.name
LEFT JOIN default.pg_beer_type AS bt ON d.beer_type_name = bt.name;

## Заполнение Many-to-Many связей (Пивная еда и вкусы)
-- 1. Связи Many-to-Many для еды
INSERT INTO default.pg_drink_food
SELECT d.drink_id, f.id AS food_id
FROM (
    SELECT drink_id, trimBoth(f_item) AS trimmed_f FROM default.v_beer_pre_insert
    LEFT ARRAY JOIN splitByChar(',', coalesce(food_raw, '')) AS f_item WHERE trimmed_f != ''
) AS d
INNER JOIN default.pg_food AS f ON d.trimmed_f = f.name;

-- 2. Связи Many-to-Many для вкусовых заметок
INSERT INTO default.pg_drink_tasting_note
SELECT d.drink_id, t.id AS tasting_note_id
FROM (
    SELECT drink_id, trimBoth(t_item) AS trimmed_t FROM default.v_beer_pre_insert
    LEFT ARRAY JOIN splitByChar(',', coalesce(tasting_raw, '')) AS t_item WHERE trimmed_t != ''
) AS d
INNER JOIN default.pg_tasting_note AS t ON d.trimmed_t = t.name;

## Очистка временных таблиц
DROP TABLE IF EXISTS default.tmp_beer_categories;
DROP TABLE IF EXISTS default.join_beer_category_resolver;


