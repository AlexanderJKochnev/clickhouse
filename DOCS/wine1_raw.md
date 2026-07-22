# после wine3_raw
## Создание новых справочников и расширение pg_drink
-- Новые справочники Many-to-One
CREATE TABLE default.pg_glassware (id UInt32, name String) ENGINE = MergeTree() ORDER BY id;
CREATE TABLE default.pg_scale (id UInt32, name String) ENGINE = MergeTree() ORDER BY id;
CREATE TABLE default.pg_body (id UInt32, name String) ENGINE = MergeTree() ORDER BY id;

-- Новый справочник Many-to-Many
CREATE TABLE default.pg_food (id UInt32, name String) ENGINE = MergeTree() ORDER BY id;

-- Таблица связи Many-to-Many для еды
CREATE TABLE default.pg_drink_food (drink_id UInt32, food_id UInt32) ENGINE = MergeTree() ORDER BY (drink_id, food_id);

-- РАСШИРЕНИЕ существующей таблицы без потери данных
ALTER TABLE default.pg_drink 
    ADD COLUMN `serving_temp` Nullable(String),
    ADD COLUMN `glassware_id` Nullable(UInt32),
    ADD COLUMN `scale_id` Nullable(UInt32),
    ADD COLUMN `body_id` Nullable(UInt32);


## Создание представления для маппинга и очистки wine1_raw
CREATE OR REPLACE VIEW default.v_wine1_parsed AS
SELECT
    generateUUIDv4() AS raw_row_id,
    Name AS wine,
    Brand AS winery,
    Categories AS category,
    NULL AS designation, -- Нет в этой таблице
    NULL AS varietal,    -- Нет в этой таблице
    Description AS review,
    NULL AS site_name,
    NULL AS subregion_name,
    NULL AS region_name,
    CASE 
        WHEN trimBoth(Country) IN ('US', 'USA', 'United States', 'United States of America') THEN 'US'
        ELSE nullIf(trimBoth(Country), '')
    END AS country_name,
    -- Новые поля
    nullIf(trimBoth(`Suggested Serving Temperature`), '') AS serving_temp,
    nullIf(trimBoth(`Suggested Glassware`), '') AS glassware_name,
    nullIf(trimBoth(`Sweet-Dry Scale`), '') AS scale_name,
    nullIf(trimBoth(`Body`), '') AS body_name,
    `Food Pairing` AS food_raw
FROM default.wine1_raw;

## Инкрементальное наполнение старых и новых справочников
-- 1. Страны
INSERT INTO default.pg_country (id, name)
WITH (SELECT coalesce(max(id), 0) FROM default.pg_country) AS max_id
SELECT CAST(max_id + rowNumberInAllBlocks() + 1 AS UInt32), src.country_name
FROM (SELECT country_name FROM default.v_wine1_parsed WHERE country_name IS NOT NULL GROUP BY country_name) AS src
LEFT JOIN default.pg_country AS target ON src.country_name = target.name WHERE target.name IS NULL;

-- 2. Винодельни (Brand)
INSERT INTO default.pg_winery (id, name)
WITH (SELECT coalesce(max(id), 0) FROM default.pg_winery) AS max_id
SELECT CAST(max_id + rowNumberInAllBlocks() + 1 AS UInt32), src.winery
FROM (SELECT winery FROM default.v_wine1_parsed WHERE winery IS NOT NULL GROUP BY winery) AS src
LEFT JOIN default.pg_winery AS target ON src.winery = target.name WHERE target.name IS NULL;

-- 3. Категории
INSERT INTO default.pg_category (id, name)
WITH (SELECT coalesce(max(id), 0) FROM default.pg_category) AS max_id
SELECT CAST(max_id + rowNumberInAllBlocks() + 1 AS UInt32), src.category
FROM (SELECT category FROM default.v_wine1_parsed WHERE category IS NOT NULL GROUP BY category) AS src
LEFT JOIN default.pg_category AS target ON src.category = target.name WHERE target.name IS NULL;

-- 4. НАПОЛНЕНИЕ НОВЫХ СПРАВОЧНИКОВ (Они пустые, но используем инкрементальный паттерн для надежности)
-- 2. Наполняем glassware из wine1_raw
INSERT INTO default.pg_glassware (id, name)
SELECT 
    CAST(rowNumberInAllBlocks() + 1 AS UInt32) AS id,
    g
FROM (SELECT trimBoth(`Suggested Glassware`) AS g FROM default.wine1_raw WHERE g IS NOT NULL AND g != '' GROUP BY g);

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

-- 5. Новый Many-to-Many справочник еды (Разворачиваем списки через запятую)
INSERT INTO default.pg_food (id, name)
WITH (SELECT coalesce(max(id), 0) FROM default.pg_food) AS max_id
SELECT CAST(max_id + rowNumberInAllBlocks() + 1 AS UInt32), src.trimmed_f
FROM (
    SELECT trimBoth(f_item) AS trimmed_f
    FROM default.v_wine1_parsed
    LEFT ARRAY JOIN splitByChar(',', coalesce(food_raw, '')) AS f_item
    WHERE trimmed_f != '' GROUP BY trimmed_f
) AS src
LEFT JOIN default.pg_food AS target ON src.trimmed_f = target.name WHERE target.name IS NULL;


## Вставка в pg_drink и заполнение связи pg_drink_food
CREATE OR REPLACE VIEW default.v_drink1_pre_insert AS
WITH (SELECT coalesce(max(id), 0) FROM default.pg_drink) AS max_id
SELECT 
    CAST(max_id + rowNumberInAllBlocks() + 1 AS UInt32) AS drink_id,
    *
FROM default.v_wine1_parsed;

INSERT INTO default.pg_drink
SELECT
    d.drink_id AS id,
    d.wine,
    d.review,
    w.id AS winery_id,
    NULL AS designation_id, -- Нет в этой таблице
    cat.id AS category_id,
    NULL AS site_id,        -- Нет в этой таблице
    NULL AS subregion_id,   -- Нет в этой таблице
    NULL AS region_id,      -- Нет в этой таблице
    c.id AS country_id,
    -- Заполнение новых полей:
    d.serving_temp AS serving_temp,
    gl.id AS glassware_id,
    sc.id AS scale_id,
    b.id AS body_id
FROM default.v_drink1_pre_insert AS d
LEFT JOIN default.pg_winery AS w ON d.winery = w.name
LEFT JOIN default.pg_category AS cat ON d.category = cat.name
LEFT JOIN default.pg_country AS c ON d.country_name = c.name
LEFT JOIN default.pg_glassware AS gl ON d.glassware_name = gl.name
LEFT JOIN default.pg_scale AS sc ON d.scale_name = sc.name
LEFT JOIN default.pg_body AS b ON d.body_name = b.name;


## Заполняем Many-to-Many связи для pg_drink_food:
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



## исправление
TRUNCATE TABLE default.pg_food;

INSERT INTO default.pg_food (id, name)
SELECT 
    CAST(rowNumberInAllBlocks() + 1 AS UInt32) AS id,
    trimmed_f
FROM (
    -- Разбиваем по запятой, убираем пробелы и группируем
    SELECT trimBoth(f_item) AS trimmed_f
    FROM default.wine1_raw
    LEFT ARRAY JOIN splitByChar(',', coalesce(`Food Pairing`, '')) AS f_item
    WHERE trimmed_f != ''
    GROUP BY trimmed_f
);


