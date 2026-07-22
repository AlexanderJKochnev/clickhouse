# tbs
## Расширение структуры pg_category (Пункт 4)
-- Добавляем колонку для синонимов и расширенного описания
ALTER TABLE default.pg_category 
    ADD COLUMN synonyms Array(String),
    ADD COLUMN full_name Nullable(String);

## Прописываем базовые маппинги (все в нижнем регистре для точного сравнения)
ALTER TABLE default.pg_category UPDATE synonyms = ['dessert', 'dessert wine'] WHERE id = 1;
ALTER TABLE default.pg_category UPDATE synonyms = ['fortified', 'fortified wine'] WHERE id = 2;
ALTER TABLE default.pg_category UPDATE synonyms = ['port', 'sherry', 'port/sherry'] WHERE id = 3;
ALTER TABLE default.pg_category UPDATE synonyms = ['red', 'red wine'] WHERE id = 4;
ALTER TABLE default.pg_category UPDATE synonyms = ['rose', 'rose wine', 'pink', 'pink wine', 'ros', 'ros wine'] WHERE id = 5;
ALTER TABLE default.pg_category UPDATE synonyms = ['sparkling', 'sparkling wine', 'sparkling red', 'sparkling white', 'champagne'] WHERE id = 6;
ALTER TABLE default.pg_category UPDATE synonyms = ['white', 'white wine'] WHERE id = 7;

## Создание временной таблицы для разбора токенов из wine1_raw (Пункты 1, 2, 3)
DROP TABLE IF EXISTS default.tmp_wine1_categories;

CREATE TABLE default.tmp_wine1_categories ENGINE = MergeTree() ORDER BY token AS
WITH
    splitByChar(',', lower(coalesce(Categories, ''))) AS tokens_arr
SELECT
    trimBoth(token) AS token,
    coalesce(Categories, '') AS original_string,
    -- Строгий поиск подстроки (position возвращает > 0, если слово найдено внутри токена)
    CASE
        WHEN position(token, 'sparkling') > 0 OR position(token, 'champagne') > 0 OR position(token, 'prosecco') > 0 THEN 6
        WHEN position(token, 'port') > 0 OR position(token, 'sherry') > 0 THEN 3
        WHEN position(token, 'dessert') > 0 THEN 1
        WHEN position(token, 'fortified') > 0 THEN 2
        -- Чтобы 'sparkling red' не улетел в Red, приоритет Sparkling выше, проверка Red идет ниже
        WHEN position(token, 'red') > 0 THEN 4
        WHEN position(token, 'white') > 0 OR position(token, 'zinfandel') > 0 THEN 7
        WHEN position(token, 'rose') > 0 OR position(token, 'pink') > 0 OR position(token, 'ros') > 0 OR position(token, 'moscato') > 0 THEN 5
        ELSE NULL
    END AS matched_category_id
FROM default.wine1_raw
LEFT ARRAY JOIN tokens_arr AS token
WHERE token != '';

## Изоляция подкатегорий и добавление только РЕАЛЬНО новых (Саке, Фруктовые вина и т.д.)
INSERT INTO default.pg_category (id, name, synonyms, full_name)
WITH 
    strings_with_valid_category AS (
        SELECT DISTINCT original_string FROM default.tmp_wine1_categories WHERE matched_category_id IS NOT NULL
    ),
    non_category_tokens AS (
        SELECT DISTINCT token FROM default.tmp_wine1_categories 
        WHERE original_string IN strings_with_valid_category AND matched_category_id IS NULL
    ),
    (SELECT max(id) FROM default.pg_category) AS max_id
SELECT
    CAST(max_id + rowNumberInAllBlocks() + 1 AS UInt32) AS id,
    concat(upper(substr(src_tokens.token, 1, 1)), substr(src_tokens.token, 2)) AS name,
    [src_tokens.token] AS synonyms,
    src_tokens.token AS full_name
FROM (
    -- Берем только те токены, которые вообще не смогли классифицировать на Шаге 2 
    -- и которые не являются сопутствующим мусором (non_category_tokens)
    SELECT DISTINCT token FROM default.tmp_wine1_categories
    WHERE matched_category_id IS NULL AND token NOT IN non_category_tokens
) AS src_tokens
LEFT JOIN default.pg_category AS existing ON src_tokens.token = lower(existing.name)
WHERE existing.name = '';


## сопоптставление структур 
DROP TABLE IF EXISTS default.join_category_resolver;
CREATE TABLE default.join_category_resolver (token String, id UInt32) ENGINE = Join(ANY, LEFT, token);

-- 1. Сначала заливаем маппинг из нашей очищенной временной таблицы (то, что мы успешно распознали)
INSERT INTO default.join_category_resolver
SELECT token, CAST(matched_category_id AS UInt32) FROM default.tmp_wine1_categories WHERE matched_category_id IS NOT NULL GROUP BY token, matched_category_id;

-- 2. Дописываем туда связи для новых добавленных категорий (Саке и т.д.)
INSERT INTO default.join_category_resolver
SELECT arrayJoin(synonyms) AS token, id FROM default.pg_category WHERE id > 7;

## Создание представления для генерации сквозных drink_id
CREATE OR REPLACE VIEW default.v_drink1_pre_insert AS
WITH 
    (SELECT coalesce(max(id), 0) FROM default.pg_drink) AS max_id
SELECT 
    CAST(max_id + rowNumberInAllBlocks() + 1 AS UInt32) AS drink_id,
    Name AS wine,
    Brand AS winery,
    Description AS review,
    CASE 
        WHEN trimBoth(Country) IN ('US', 'USA', 'United States', 'United States of America') THEN 'US'
        ELSE nullIf(trimBoth(Country), '')
    END AS country_name,
    nullIf(trimBoth(`Suggested Serving Temperature`), '') AS serving_temp,
    nullIf(trimBoth(`Suggested Glassware`), '') AS glassware_name,
    nullIf(trimBoth(`Sweet-Dry Scale`), '') AS scale_name,
    nullIf(trimBoth(`Body`), '') AS body_name,
    `Food Pairing` AS food_raw,
    -- Хитрый подзапрос: бьем категории строки на токены и ищем их ID в резолвере, берем минимальный
    (
        SELECT min(joinGet('default.join_category_resolver', 'id', trimBoth(token)))
        FROM (SELECT arrayJoin(splitByChar(',', lower(coalesce(Categories, '')))) AS token)
        WHERE joinGet('default.join_category_resolver', 'id', trimBoth(token)) > 0
    ) AS resolved_category_id
FROM default.wine1_raw;

## Перенос данных в главную таблицу pg_drink
INSERT INTO default.pg_drink
SELECT
    d.drink_id AS id,
    d.wine,
    d.review,
    w.id AS winery_id,
    NULL AS designation_id,
    nullIf(d.resolved_category_id, 0) AS category_id, -- Подставит NULL, если категория не нашлась
    NULL AS site_id,
    NULL AS subregion_id,
    NULL AS region_id,
    c.id AS country_id,
    d.serving_temp AS serving_temp,
    gl.id AS glassware_id,
    sc.id AS scale_id,
    b.id AS body_id
FROM default.v_drink1_pre_insert AS d
LEFT JOIN default.pg_winery AS w ON d.winery = w.name
LEFT JOIN default.pg_country AS c ON d.country_name = c.name
LEFT JOIN default.pg_glassware AS gl ON d.glassware_name = gl.name
LEFT JOIN default.pg_scale AS sc ON d.scale_name = sc.name
LEFT JOIN default.pg_body AS b ON d.body_name = b.name;

## Заполнение связей Many-to-Many для еды
INSERT INTO default.pg_drink_food
SELECT 
    d.drink_id,
    f.id AS food_id
FROM (
    SELECT drink_id, trimBoth(f_item) AS trimmed_f
    FROM default.v_drink1_pre_insert
    LEFT ARRAY JOIN splitByChar(',', coalesce(food_raw, '')) AS f_item
    WHERE trimmed_f != ''
) AS d
INNER JOIN default.pg_food AS f ON d.trimmed_f = f.name;

## Очистка временных структур этого этапа
DROP TABLE IF EXISTS default.tmp_wine1_categories;
DROP TABLE IF EXISTS default.join_category_resolver;



-----------------
## 1. Перезаполнение справочников напрямую из сырых таблиц
-- Очищаем справочники от нулей
TRUNCATE TABLE default.pg_category;
TRUNCATE TABLE default.pg_glassware;
TRUNCATE TABLE default.pg_scale;
TRUNCATE TABLE default.pg_body;

-- 1. Наполняем категории из wine4_raw
INSERT INTO default.pg_category (id, name)
SELECT 
    CAST(rowNumberInAllBlocks() + 1 AS UInt32) AS id,
    category
FROM (SELECT trimBoth(category) AS category FROM default.wine4_raw WHERE category IS NOT NULL AND category != '' GROUP BY category);

-- 2. Наполняем glassware из wine1_raw
INSERT INTO default.pg_glassware (id, name)
SELECT 
    CAST(rowNumberInAllBlocks() + 1 AS UInt32) AS id,
    g
FROM (SELECT trimBoth(`Suggested Glassware`) AS g FROM default.wine1_raw WHERE g IS NOT NULL AND g != '' GROUP BY g);

-- 3. Наполняем scale из wine1_raw
INSERT INTO default.pg_scale (id, name)
SELECT 
    CAST(rowNumberInAllBlocks() + 1 AS UInt32) AS id,
    s
FROM (SELECT trimBoth(`Sweet-Dry Scale`) AS s FROM default.wine1_raw WHERE s IS NOT NULL AND s != '' GROUP BY s);

-- 4. Наполняем body из wine1_raw
INSERT INTO default.pg_body (id, name)
SELECT 
    CAST(rowNumberInAllBlocks() + 1 AS UInt32) AS id,
    b
FROM (SELECT trimBoth(`Body`) AS b FROM default.wine1_raw WHERE b IS NOT NULL AND b != '' GROUP BY b);


wait
## Исправление связей в pg_drink через подзапросы
-- Создаем временные Join-таблицы для быстрого поиска ID по имени
CREATE TABLE default.join_category (name String, id UInt32) ENGINE = Join(ANY, LEFT, name);
CREATE TABLE default.join_glassware (name String, id UInt32) ENGINE = Join(ANY, LEFT, name);
CREATE TABLE default.join_scale (name String, id UInt32) ENGINE = Join(ANY, LEFT, name);
CREATE TABLE default.join_body (name String, id UInt32) ENGINE = Join(ANY, LEFT, name);

-- Переливаем в них данные
INSERT INTO default.join_category SELECT name, id FROM default.pg_category;
INSERT INTO default.join_glassware SELECT name, id FROM default.pg_glassware;
INSERT INTO default.join_scale SELECT name, id FROM default.pg_scale;
INSERT INTO default.join_body SELECT name, id FROM default.pg_body;

## Выполнение мутаций (UPDATE)
-- 1. Обновляем category_id, сопоставляя через сырую таблицу wine4_raw
ALTER TABLE default.pg_drink 
UPDATE category_id = joinGet('default.join_category', 'id', (
    SELECT trimBoth(category) FROM default.wine4_raw WHERE default.wine4_raw.wine = default.pg_drink.wine LIMIT 1
))
WHERE category_id = 0 OR category_id IS NULL;

-- 2. Обновляем glassware_id
ALTER TABLE default.pg_drink 
UPDATE glassware_id = joinGet('default.join_glassware', 'id', (
    SELECT trimBoth(`Suggested Glassware`) FROM default.wine1_raw WHERE default.wine1_raw.Name = default.pg_drink.wine LIMIT 1
))
WHERE glassware_id = 0 OR glassware_id IS NULL;

-- 3. Обновляем scale_id
ALTER TABLE default.pg_drink 
UPDATE scale_id = joinGet('default.join_scale', 'id', (
    SELECT trimBoth(`Sweet-Dry Scale`) FROM default.wine1_raw WHERE default.wine1_raw.Name = default.pg_drink.wine LIMIT 1
))
WHERE scale_id = 0 OR scale_id IS NULL;

-- 4. Обновляем body_id
ALTER TABLE default.pg_drink 
UPDATE body_id = joinGet('default.join_body', 'id', (
    SELECT trimBoth(`Body`) FROM default.wine1_raw WHERE default.wine1_raw.Name = default.pg_drink.wine LIMIT 1
))
WHERE body_id = 0 OR body_id IS NULL;

## Очистка временных таблиц
После того как команды ALTER завершатся 
(проверить статус выполнения мутаций можно командой 
SELECT * FROM system.mutations WHERE is_done = 0), 
временные таблицы можно удалить:
DROP TABLE default.join_category;
DROP TABLE default.join_glassware;
DROP TABLE default.join_scale;
DROP TABLE default.join_body;
