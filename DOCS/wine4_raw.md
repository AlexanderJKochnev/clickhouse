# создание таблиц
-- 1. Страны
CREATE TABLE default.pg_country (id UInt32, name String) ENGINE = MergeTree() ORDER BY id;

-- 1.1. Категории
CREATE TABLE default.pg_category 
(
    id UInt32, 
    name String
) 
ENGINE = MergeTree() 
ORDER BY id;


-- 2. Регионы
CREATE TABLE default.pg_region (id UInt32, name String, country_id Nullable(UInt32)) ENGINE = MergeTree() ORDER BY id;

-- 3. Субрегионы
CREATE TABLE default.pg_subregion (id UInt32, name String, region_id Nullable(UInt32)) ENGINE = MergeTree() ORDER BY id;

-- 4. Сайты / Аппелласьоны
CREATE TABLE default.pg_site (id UInt32, name String, subregion_id Nullable(UInt32)) ENGINE = MergeTree() ORDER BY id;

-- 5. Винодельни
CREATE TABLE default.pg_winery (id UInt32, name String) ENGINE = MergeTree() ORDER BY id;

-- 6. Обозначения (Designation)
CREATE TABLE default.pg_designation (id UInt32, name String) ENGINE = MergeTree() ORDER BY id;

-- 7. Сорта винограда (Varietal)
CREATE TABLE default.pg_varietal (id UInt32, name String) ENGINE = MergeTree() ORDER BY id;

-- 8. Главная таблица напитков (Drink)
DROP TABLE IF EXISTS default.pg_drink;

CREATE TABLE default.pg_drink
(
    id UInt32,
    wine Nullable(String),
    review Nullable(String),
    winery_id Nullable(UInt32),
    designation_id Nullable(UInt32),
    category_id Nullable(UInt32), -- Новое поле для связи
    site_id Nullable(UInt32),
    subregion_id Nullable(UInt32),
    region_id Nullable(UInt32),
    country_id Nullable(UInt32)
) ENGINE = MergeTree() ORDER BY id;


-- 9. Таблица связи Many-to-Many (Drink <-> Varietal)
CREATE TABLE default.pg_drink_varietal (drink_id UInt32, varietal_id UInt32) ENGINE = MergeTree() ORDER BY (drink_id, varietal_id);

# view for appellation
CREATE VIEW default.v_wine_parsed AS
WITH
    replaceRegexpAll(coalesce(appellation, ''), ', ', ',') AS clean_str,
    splitByChar(',', clean_str) AS arr,
    arrayReverse(arr) AS reversed_arr,
    arrayResize(reversed_arr, 4, '') AS fixed_arr,
    arrayReverse(fixed_arr) AS final_arr
SELECT
    -- Генерируем временный UUID для каждой строки сырых данных, чтобы связать Many-to-Many
    generateUUIDv4() AS raw_row_id,
    wine, winery, category, designation, varietal, alcohol, reviewer, review,
    nullIf(final_arr[1], '') AS site_name,
    nullIf(final_arr[2], '') AS subregion_name,
    nullIf(final_arr[3], '') AS region_name,
    nullIf(final_arr[4], '') AS country_name
FROM default.wine4_raw;

# наполнение таблиц 1
-- 1. Страны
INSERT INTO default.pg_country (id, name)
SELECT CAST(dense_rank() OVER (ORDER BY country_name) AS UInt32) AS id, country_name
FROM default.v_wine_parsed WHERE country_name IS NOT NULL GROUP BY country_name;

-- 2. Регионы (с привязкой к country_id)
INSERT INTO default.pg_region (id, name, country_id)
SELECT 
    CAST(dense_rank() OVER (ORDER BY r.region_name) AS UInt32) AS id,
    r.region_name,
    c.id AS country_id
FROM (SELECT region_name, country_name FROM default.v_wine_parsed WHERE region_name IS NOT NULL GROUP BY region_name, country_name) AS r
LEFT JOIN default.pg_country AS c ON r.country_name = c.name;

-- 3. Субрегионы (с привязкой к region_id)
INSERT INTO default.pg_subregion (id, name, region_id)
SELECT 
    CAST(dense_rank() OVER (ORDER BY s.subregion_name) AS UInt32) AS id,
    s.subregion_name,
    r.id AS region_id
FROM (SELECT subregion_name, region_name FROM default.v_wine_parsed WHERE subregion_name IS NOT NULL GROUP BY subregion_name, region_name) AS s
LEFT JOIN default.pg_region AS r ON s.region_name = r.name;

-- 4. Сайты (с привязкой к subregion_id)
INSERT INTO default.pg_site (id, name, subregion_id)
SELECT 
    CAST(dense_rank() OVER (ORDER BY st.site_name) AS UInt32) AS id,
    st.site_name,
    s.id AS subregion_id
FROM (SELECT site_name, subregion_name FROM default.v_wine_parsed WHERE site_name IS NOT NULL GROUP BY site_name, subregion_name) AS st
LEFT JOIN default.pg_subregion AS s ON st.subregion_name = s.name;

# наполнение таблиц 2
-- 5. Винодельни
INSERT INTO default.pg_winery (id, name)
SELECT CAST(dense_rank() OVER (ORDER BY winery) AS UInt32) AS id, winery
FROM default.v_wine_parsed WHERE winery IS NOT NULL GROUP BY winery;

-- 6. Обозначения
INSERT INTO default.pg_designation (id, name)
SELECT CAST(dense_rank() OVER (ORDER BY designation) AS UInt32) AS id, designation
FROM default.v_wine_parsed WHERE designation IS NOT NULL GROUP BY designation;

-- 7. Сорта винограда (Разворачиваем списки через запятую в отдельные строки с помощью arrayJoin)
INSERT INTO default.pg_varietal (id, name)
SELECT 
    CAST(dense_rank() OVER (ORDER BY trimmed_v) AS UInt32) AS id,
    trimmed_v AS name
FROM (
    SELECT trimBoth(v_item) AS trimmed_v
    FROM default.v_wine_parsed
    LEFT ARRAY JOIN splitByChar(',', coalesce(varietal, '')) AS v_item
    WHERE trimmed_v != ''
    GROUP BY trimmed_v
);

--8. category
INSERT INTO default.pg_category (id, name)
SELECT 
    CAST(dense_rank() OVER (ORDER BY category) AS UInt32) AS id, 
    category
FROM default.v_wine_parsed 
WHERE category IS NOT NULL 
GROUP BY category;

# interim view
CREATE VIEW default.v_drink_pre_insert AS
SELECT 
    CAST(rowNumberInAllBlocks() + 1 AS UInt32) AS drink_id,
    *
FROM default.v_wine_parsed;


# заполнение pg_drink
INSERT INTO default.pg_drink
SELECT
    d.drink_id AS id,
    d.wine,
    d.review,
    w.id AS winery_id,
    dg.id AS designation_id,
    cat.id AS category_id, -- Подтягиваем ID категории
    st.id AS site_id,
    sr.id AS subregion_id,
    r.id AS region_id,
    c.id AS country_id
FROM default.v_drink_pre_insert AS d
LEFT JOIN default.pg_winery AS w ON d.winery = w.name
LEFT JOIN default.pg_designation AS dg ON d.designation = dg.name
LEFT JOIN default.pg_category AS cat ON d.category = cat.name -- JOIN категорий
LEFT JOIN default.pg_site AS st ON d.site_name = st.name
LEFT JOIN default.pg_subregion AS sr ON d.subregion_name = sr.name
LEFT JOIN default.pg_region AS r ON d.region_name = r.name
LEFT JOIN default.pg_country AS c ON d.country_name = c.name;

# заполнение pg_drink_varietal
INSERT INTO default.pg_drink_varietal
SELECT 
    d.drink_id,
    v.id AS varietal_id
FROM (
    -- Снова разворачиваем сорта, сохраняя ID напитка
    SELECT drink_id, trimBoth(v_item) AS trimmed_v
    FROM default.v_drink_pre_insert
    LEFT ARRAY JOIN splitByChar(',', coalesce(varietal, '')) AS v_item
    WHERE trimmed_v != ''
) AS d
INNER JOIN default.pg_varietal AS v ON d.trimmed_v = v.name;

# mutation
-- 1. Добавляем колонку
ALTER TABLE default.pg_drink ADD COLUMN category_id Nullable(UInt32);

-- 2. Запускаем обновление данных через JOIN со справочником (в ClickHouse это делается через UPDATE ... FROM)
ALTER TABLE default.pg_drink UPDATE category_id = cat.id
FROM default.pg_category AS cat
WHERE default.pg_drink.wine IN (
    SELECT wine FROM default.v_drink_pre_insert WHERE category = cat.name
);