# выполнять поcле wine4_raw.md
## нормализация колонок
CREATE OR REPLACE VIEW default.v_wine3_parsed AS
SELECT
    generateUUIDv4() AS raw_row_id,
    title AS wine,
    winery,
    NULL AS category, -- В этой таблице нет категории
    designation,
    variety AS varietal, 
    description AS review,
    nullIf(trimBoth(region_2), '') AS site_name,
    nullIf(trimBoth(region_1), '') AS subregion_name,
    nullIf(trimBoth(province), '') AS region_name,
    -- Нормализация коллизий для США
    CASE 
        WHEN trimBoth(country) IN ('US', 'USA', 'United States', 'United States of America') THEN 'US'
        ELSE nullIf(trimBoth(country), '')
    END AS country_name
FROM default.wine3_raw;

## Инкрементальное наполнение географических справочников
-- 1. Страны (Добавляем только новые)
INSERT INTO default.pg_country (id, name)
WITH (SELECT coalesce(max(id), 0) FROM default.pg_country) AS max_id
SELECT 
    CAST(max_id + rowNumberInAllBlocks() + 1 AS UInt32) AS id,
    src.country_name AS name
FROM (SELECT country_name FROM default.v_wine3_parsed WHERE country_name IS NOT NULL GROUP BY country_name) AS src
LEFT JOIN default.pg_country AS target ON src.country_name = target.name
WHERE target.name IS NULL;

-- 2. Регионы (Добавляем только новые с привязкой к country_id)
INSERT INTO default.pg_region (id, name, country_id)
WITH (SELECT coalesce(max(id), 0) FROM default.pg_region) AS max_id
SELECT 
    CAST(max_id + rowNumberInAllBlocks() + 1 AS UInt32) AS id,
    src.region_name AS name,
    c.id AS country_id
FROM (SELECT region_name, country_name FROM default.v_wine3_parsed WHERE region_name IS NOT NULL GROUP BY region_name, country_name) AS src
LEFT JOIN default.pg_region AS target ON src.region_name = target.name
LEFT JOIN default.pg_country AS c ON src.country_name = c.name
WHERE target.name IS NULL;

-- 3. Субрегионы
INSERT INTO default.pg_subregion (id, name, region_id)
WITH (SELECT coalesce(max(id), 0) FROM default.pg_subregion) AS max_id
SELECT 
    CAST(max_id + rowNumberInAllBlocks() + 1 AS UInt32) AS id,
    src.subregion_name AS name,
    r.id AS region_id
FROM (SELECT subregion_name, region_name FROM default.v_wine3_parsed WHERE subregion_name IS NOT NULL GROUP BY subregion_name, region_name) AS src
LEFT JOIN default.pg_subregion AS target ON src.subregion_name = target.name
LEFT JOIN default.pg_region AS r ON src.region_name = r.name
WHERE target.name IS NULL;

-- 4. Сайты (Аппелласьоны)
INSERT INTO default.pg_site (id, name, subregion_id)
WITH (SELECT coalesce(max(id), 0) FROM default.pg_site) AS max_id
SELECT 
    CAST(max_id + rowNumberInAllBlocks() + 1 AS UInt32) AS id,
    src.site_name AS name,
    s.id AS subregion_id
FROM (SELECT site_name, subregion_name FROM default.v_wine3_parsed WHERE site_name IS NOT NULL GROUP BY site_name, subregion_name) AS src
LEFT JOIN default.pg_site AS target ON src.site_name = target.name
LEFT JOIN default.pg_subregion AS s ON src.subregion_name = s.name
WHERE target.name IS NULL;

## Инкрементальное наполнение остальных справочников
-- 5. Винодельни
INSERT INTO default.pg_winery (id, name)
WITH (SELECT coalesce(max(id), 0) FROM default.pg_winery) AS max_id
SELECT 
    CAST(max_id + rowNumberInAllBlocks() + 1 AS UInt32) AS id,
    src.winery AS name
FROM (SELECT winery FROM default.v_wine3_parsed WHERE winery IS NOT NULL GROUP BY winery) AS src
LEFT JOIN default.pg_winery AS target ON src.winery = target.name
WHERE target.name IS NULL;

-- 6. Обозначения (Designation)
INSERT INTO default.pg_designation (id, name)
WITH (SELECT coalesce(max(id), 0) FROM default.pg_designation) AS max_id
SELECT 
    CAST(max_id + rowNumberInAllBlocks() + 1 AS UInt32) AS id,
    src.designation AS name
FROM (SELECT designation FROM default.v_wine3_parsed WHERE designation IS NOT NULL GROUP BY designation) AS src
LEFT JOIN default.pg_designation AS target ON src.designation = target.name
WHERE target.name IS NULL;

-- 7. Сорта винограда (Varietal)
INSERT INTO default.pg_varietal (id, name)
WITH (SELECT coalesce(max(id), 0) FROM default.pg_varietal) AS max_id
SELECT 
    CAST(max_id + rowNumberInAllBlocks() + 1 AS UInt32) AS id,
    src.trimmed_v AS name
FROM (
    SELECT trimBoth(v_item) AS trimmed_v
    FROM default.v_wine3_parsed
    LEFT ARRAY JOIN splitByChar(',', coalesce(varietal, '')) AS v_item
    WHERE trimmed_v != ''
    GROUP BY trimmed_v
) AS src
LEFT JOIN default.pg_varietal AS target ON src.trimmed_v = target.name
WHERE target.name IS NULL;

## Наполнение таблицы Drink и связей Many-to-Many для таблицы №2
### 1.
CREATE OR REPLACE VIEW default.v_drink3_pre_insert AS
WITH (SELECT coalesce(max(id), 0) FROM default.pg_drink) AS max_id
SELECT 
    CAST(max_id + rowNumberInAllBlocks() + 1 AS UInt32) AS drink_id,
    *
FROM default.v_wine3_parsed;

### 2.
INSERT INTO default.pg_drink
SELECT
    d.drink_id AS id,
    d.wine,
    d.review,
    w.id AS winery_id,
    dg.id AS designation_id,
    NULL AS category_id, -- Категории в этой таблице нет
    st.id AS site_id,
    sr.id AS subregion_id,
    r.id AS region_id,
    c.id AS country_id
FROM default.v_drink3_pre_insert AS d
LEFT JOIN default.pg_winery AS w ON d.winery = w.name
LEFT JOIN default.pg_designation AS dg ON d.designation = dg.name
LEFT JOIN default.pg_site AS st ON d.site_name = st.name
LEFT JOIN default.pg_subregion AS sr ON d.subregion_name = sr.name
LEFT JOIN default.pg_region AS r ON d.region_name = r.name
LEFT JOIN default.pg_country AS c ON d.country_name = c.name;

## Дописываем новые связи Many-to-Many в pg_drink_varietal
INSERT INTO default.pg_drink_varietal
SELECT 
    d.drink_id,
    v.id AS varietal_id
FROM (
    SELECT drink_id, trimBoth(v_item) AS trimmed_v
    FROM default.v_drink3_pre_insert
    LEFT ARRAY JOIN splitByChar(',', coalesce(varietal, '')) AS v_item
    WHERE trimmed_v != ''
) AS d
INNER JOIN default.pg_varietal AS v ON d.trimmed_v = v.name;
