# последняя таблица

## Создание новых справочников и расширение pg_drink
-- 1. Новые справочники Many-to-Many
CREATE TABLE default.pg_ingredient (id UInt32, name String) ENGINE = MergeTree() ORDER BY id;
CREATE TABLE default.pg_tasting_note (id UInt32, name String) ENGINE = MergeTree() ORDER BY id;

-- 2. Таблицы связей Many-to-Many
CREATE TABLE default.pg_drink_ingredient (drink_id UInt32, ingredient_id UInt32) ENGINE = MergeTree() ORDER BY (drink_id, ingredient_id);
CREATE TABLE default.pg_drink_tasting_note (drink_id UInt32, tasting_note_id UInt32) ENGINE = MergeTree() ORDER BY (drink_id, tasting_note_id);

-- 3. РАСШИРЕНИЕ главной таблицы новыми полями для крепкого алкоголя
ALTER TABLE default.pg_drink 
    ADD COLUMN `abv` Nullable(String),
    ADD COLUMN `years_aged` Nullable(Int16);

## Анализ и нормализация категорий (Схлопывание крепкого алкоголя)
DROP TABLE IF EXISTS default.tmp_spirits_categories;

CREATE TABLE default.tmp_spirits_categories ENGINE = MergeTree() ORDER BY token AS
WITH
    splitByChar(',', lower(coalesce(Categories, ''))) AS tokens_arr
SELECT
    trimBoth(token) AS token,
    coalesce(Categories, '') AS original_string,
    -- Проверяем, вдруг какие-то категории пересекаются со старыми, 
    -- а для новых крепких напитков пока ставим NULL (выделим их на следующем шаге)
    CASE
        WHEN position(token, 'sparkling') > 0 OR position(token, 'champagne') > 0 THEN 6
        WHEN position(token, 'port') > 0 OR position(token, 'sherry') > 0 THEN 3
        WHEN position(token, 'dessert') > 0 THEN 1
        WHEN position(token, 'fortified') > 0 THEN 2
        WHEN position(token, 'red') > 0 THEN 4
        WHEN position(token, 'white') > 0 THEN 7
        WHEN position(token, 'rose') > 0 OR position(token, 'pink') > 0 OR position(token, 'ros') > 0 THEN 5
        ELSE NULL
    END AS matched_category_id
FROM default.spirits_raw
LEFT ARRAY JOIN tokens_arr AS token
WHERE token != '';

## Добавляем РЕАЛЬНО новые категории (Виски, Водка, Джин, Ром и т.д.):

INSERT INTO default.pg_category (id, name, synonyms, full_name)
WITH 
    strings_with_valid_category AS (
        SELECT DISTINCT original_string FROM default.tmp_spirits_categories WHERE matched_category_id IS NOT NULL
    ),
    non_category_tokens AS (
        SELECT DISTINCT token FROM default.tmp_spirits_categories 
        WHERE original_string IN strings_with_valid_category AND matched_category_id IS NULL
    ),
    (SELECT max(id) FROM default.pg_category) AS max_id
SELECT
    CAST(max_id + rowNumberInAllBlocks() + 1 AS UInt32) AS id,
    concat(upper(substr(src_tokens.token, 1, 1)), substr(src_tokens.token, 2)) AS name,
    [src_tokens.token] AS synonyms,
    src_tokens.token AS full_name
FROM (
    SELECT DISTINCT token FROM default.tmp_spirits_categories
    WHERE matched_category_id IS NULL AND token NOT IN non_category_tokens
) AS src_tokens
LEFT JOIN default.pg_category AS existing ON src_tokens.token = lower(existing.name)
WHERE existing.name = '';

## Создаем и заполняем точечный резолвер для этой таблицы:
DROP TABLE IF EXISTS default.join_spirits_category_resolver;
CREATE TABLE default.join_spirits_category_resolver (token String, id UInt32) ENGINE = Join(ANY, LEFT, token);

INSERT INTO default.join_spirits_category_resolver
SELECT token, CAST(matched_category_id AS UInt32) FROM default.tmp_spirits_categories WHERE matched_category_id IS NOT NULL GROUP BY token, matched_category_id;

INSERT INTO default.join_spirits_category_resolver
SELECT arrayJoin(synonyms) AS token, id FROM default.pg_category WHERE id > 7;

## Наполнение новых Many-to-Many справочников (Ингредиенты и Вкусы)
-- 1. Базовые ингредиенты
INSERT INTO default.pg_ingredient (id, name)
SELECT CAST(rowNumberInAllBlocks() + 1 AS UInt32), trimmed_i
FROM (
    SELECT trimBoth(i_item) AS trimmed_i FROM default.spirits_raw
    LEFT ARRAY JOIN splitByChar(',', coalesce(`Base Ingredient`, '')) AS i_item
    WHERE trimmed_i != '' GROUP BY trimmed_i
);

-- 2. Вкусовые заметки (Tasting Notes)
INSERT INTO default.pg_tasting_note (id, name)
SELECT CAST(rowNumberInAllBlocks() + 1 AS UInt32), trimmed_t
FROM (
    SELECT trimBoth(t_item) AS trimmed_t FROM default.spirits_raw
    LEFT ARRAY JOIN splitByChar(',', coalesce(`Tasting Notes`, '')) AS t_item
    WHERE trimmed_t != '' GROUP BY trimmed_t
);

## Инкрементальное наполнение старых справочников (Страны и Бренды)
-- 1. Страны
INSERT INTO default.pg_country (id, name)
WITH (SELECT coalesce(max(id), 0) FROM default.pg_country) AS max_id
SELECT CAST(max_id + rowNumberInAllBlocks() + 1 AS UInt32), src.c_name
FROM (
    SELECT CASE 
        WHEN trimBoth(Country) IN ('US', 'USA', 'United States', 'United States of America') THEN 'US'
        ELSE nullIf(trimBoth(Country), '')
    END AS c_name FROM default.spirits_raw WHERE c_name IS NOT NULL GROUP BY c_name
) AS src
LEFT JOIN default.pg_country AS target ON src.c_name = target.name WHERE target.name IS NULL;

-- 2. Бренды (Winery / Brand)
INSERT INTO default.pg_winery (id, name)
WITH (SELECT coalesce(max(id), 0) FROM default.pg_winery) AS max_id
SELECT CAST(max_id + rowNumberInAllBlocks() + 1 AS UInt32), src.Brand
FROM (SELECT Brand FROM default.spirits_raw WHERE Brand IS NOT NULL GROUP BY Brand) AS src
LEFT JOIN default.pg_winery AS target ON src.Brand = target.name WHERE target.name IS NULL;

## Сборка представления и перенос данных в pg_drink
CREATE OR REPLACE VIEW default.v_spirits_pre_insert AS
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
    nullIf(trimBoth(ABV), '') AS abv,
    `Years Aged` AS years_aged,
    `Base Ingredient` AS ingredient_raw,
    `Tasting Notes` AS tasting_raw,
    (
        SELECT min(joinGet('default.join_spirits_category_resolver', 'id', trimBoth(token)))
        FROM (SELECT arrayJoin(splitByChar(',', lower(coalesce(Categories, '')))) AS token)
        WHERE joinGet('default.join_spirits_category_resolver', 'id', trimBoth(token)) > 0
    ) AS resolved_category_id
FROM default.spirits_raw;

## Вставляем данные в главную таблицу:
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
    d.abv AS abv,
    CAST(d.years_aged AS Nullable(Int16)) AS years_aged
FROM default.v_spirits_pre_insert AS d
LEFT JOIN default.pg_winery AS w ON d.winery = w.name
LEFT JOIN default.pg_country AS c ON d.country_name = c.name;

## Заполнение Many-to-Many связей для Ингредиентов и Вкусов
-- 1. Связи ингредиентов
INSERT INTO default.pg_drink_ingredient
SELECT d.drink_id, i.id AS ingredient_id
FROM (
    SELECT drink_id, trimBoth(i_item) AS trimmed_i FROM default.v_spirits_pre_insert
    LEFT ARRAY JOIN splitByChar(',', coalesce(ingredient_raw, '')) AS i_item WHERE trimmed_i != ''
) AS d
INNER JOIN default.pg_ingredient AS i ON d.trimmed_i = i.name;

-- 2. Связи вкусовых заметок
INSERT INTO default.pg_drink_tasting_note
SELECT d.drink_id, t.id AS tasting_note_id
FROM (
    SELECT drink_id, trimBoth(t_item) AS trimmed_t FROM default.v_spirits_pre_insert
    LEFT ARRAY JOIN splitByChar(',', coalesce(tasting_raw, '')) AS t_item WHERE trimmed_t != ''
) AS d
INNER JOIN default.pg_tasting_note AS t ON d.trimmed_t = t.name;

## Очистка
DROP TABLE IF EXISTS default.tmp_spirits_categories;
DROP TABLE IF EXISTS default.join_spirits_category_resolver;

