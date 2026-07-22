#  новый подход - собираем сырые данные в ch. дедуплицируем и отдаем в postgresql

## ШАГ 1. Создание новой монолитной таблицы в ClickHouse 26.4
DROP TABLE IF EXISTS tmp.flat_drinks_lake;
CREATE TABLE tmp.flat_drinks_lake
(
    id UInt32,
    wine Nullable(String),
    review Nullable(String),
    winery Nullable(String),
    designation Nullable(String),
    category Nullable(String),
    subcategory Nullable(String),
    site Nullable(String),
    subregion Nullable(String),
    region Nullable(String),
    country Nullable(String),
    glassware Nullable(String),
    scale Nullable(String),
    body Nullable(String),
    abv Nullable(String),
    years_aged Nullable(Int16),
    varietals Array(String),
    foods Array(String),
    beer_type Array(String),
    source String,
    tasting_notes Array(String),
    base_ingredient Array(String),
) ENGINE = MergeTree()
ORDER BY id;

## ШАГ 2. Потоковое наполнение из первого файла wine4_raw
INSERT INTO tmp.flat_drinks_lake
WITH
    t AS (
        SELECT *,
               ROW_NUMBER() OVER (PARTITION BY wine ORDER BY wine) as rn
        FROM wine4_raw
        WHERE review IS NOT NULL
    ),
    -- 1. Срезаем лишние пробелы и парсим массив appellation с конца (через переворот)
    replaceRegexpAll(coalesce(appellation, ''), ', ', ',') AS clean_app,
    splitByChar(',', clean_app) AS app_arr,
    arrayReverse(app_arr) AS rev_app,
    arrayResize(rev_app, 4, '') AS fixed_app,
    arrayReverse(fixed_app) AS final_app,
SELECT
    -- Генерируем порядковый счетчик для первой пачки данных
    CAST(rowNumberInAllBlocks() + 1 AS UInt32) AS id,
    wine,
    review,
    winery,
    designation,
    'Wine' AS category,                -- Фиксированное значение по вашей инструкции
    t.category AS subcategory,           -- Данные уходят в подкатегорию
    -- Извлекаем распарсенную географию (пустые элементы станут NULL)
    nullIf(final_app[1], '') AS site,
    nullIf(final_app[2], '') AS subregion,
    nullIf(final_app[3], '') AS region,
    nullIf(final_app[4], '') AS country,
    -- Поля из других файлов заполняем NULL
    NULL AS glassware,
    NULL AS scale,
    NULL AS body,
    NULL AS abv,
    NULL AS years_aged,
    -- Разрезаем varietal по запятой, чистим пробелы у каждого элемента и пишем в массив
    arrayMap(x -> trimBoth(x), splitByChar(',', coalesce(varietal, ''))) AS varietals,
    [] AS foods,
    arrayMap(x -> trimBoth(x), splitByChar(',', coalesce(subcategory, ''))) AS beer_type,
    'wine4_raw' AS source,
    [] AS tasting_notes,
    [] AS base_ingredient
FROM  t
WHERE appellation NOT LIKE '%DrizlyVivino%' 
  AND appellation NOT LIKE '%Buy Now%'
  AND wine NOT LIKE '$%' 
  AND winery NOT LIKE '$%';

## ШАГ 3. Потоковое наполнение из первого файла wine3_raw (province/region1/region2) ДОДЕЛАТЬ
#### доделать - нет субкатегории 4241 запись
INSERT INTO tmp.flat_drinks_lake
WITH
    -- Вычисляем стартовый ID на основе текущего максимума
    (SELECT coalesce(max(id), 0) FROM tmp.flat_drinks_lake) AS max_id,
    a AS (
    SELECT *
    FROM wine3_raw
    ), b AS (
    SELECT wine 
    FROM tmp.flat_drinks_lake
    ), t AS (
    SELECT a.*
    FROM a
    LEFT JOIN b
    ON a.title = b.wine
    WHERE b.wine IS NULL)
SELECT
    CAST(max_id + rowNumberInAllBlocks() + 1 AS UInt32) AS id,
    title AS wine,
    description AS review,
    winery,
    designation,
    'Wine' AS category,                     -- Жестко по инструкции
    NULL AS subcategory,                    -- В этой таблице подкатегории нет
    nullif(trimBoth(coalesce(region_2, region_1)), NULL) AS subregion,
    CASE WHEN region_2 IS NULL THEN NULL
         ELSE nullif(trimBoth(region_1), NULL) END AS site, 
    nullIf(trimBoth(province), '') AS region,
    multiIf(trimBoth(country) IN ('US', 'USA', 'United States', 'United States of America'), 'US', nullIf(trimBoth(country), '')) AS country,
    NULL AS glassware,
    NULL AS scale,
    NULL AS body,
    NULL AS abv,
    NULL AS years_aged,
    -- Помещаем variety в массив varietals (разбиваем по запятой, если есть перечисления, и чистим пробелы)
    arrayMap(x -> trimBoth(x), splitByChar(',', coalesce(variety, ''))) AS varietals,
    [] AS foods,
    [] AS beer_type,
    'wine3_raw' AS source,
    [] AS tasting_notes,
    [] AS base_ingredient
FROM t -- default.wine3_raw
WHERE title NOT LIKE '$%' 
  AND winery NOT LIKE '$%'

## ШАГ 4. wine1_raw (geo - только country) DONE
INSERT INTO tmp.flat_drinks_lake
WITH w AS (
SELECT * FROM wine1_raw 
WHERE Description IS NOT NULL
), o AS (
SELECT wine
FROM tmp.flat_drinks_lake 
), t AS (
SELECT w.* 
FROM w
LEFT JOIN o
ON w.Name = o.wine
WHERE o.wine IS NULL
),
(SELECT coalesce(max(id), 0) FROM tmp.flat_drinks_lake) AS max_id
SELECT
    CAST(max_id + rowNumberInAllBlocks() + 1 AS UInt32) AS id,
    Name AS wine,
    Description AS review,
    Brand AS winery,
    NULL AS designation,
    NULL AS category,
    NULL AS subcategory,
    NULL AS site,
    NULL AS subregion,
    NULL AS region,
    multiIf(trimBoth(Country) IN ('US', 'USA', 'United States', 'United States of America'), 'US', nullIf(trimBoth(Country), '')) AS country,
    nullIf(trimBoth(`Suggested Glassware`), '') AS glassware,
    nullIf(trimBoth(`Sweet-Dry Scale`), '') AS scale,
    nullIf(trimBoth(`Body`), '') AS body,
    NULL AS abv,
    NULL AS years_aged,
    [] AS varietals,
    arrayMap(x -> trimBoth(x), splitByChar(',', coalesce(`Food Pairing`, ''))) AS foods,
    arrayMap(x -> trimBoth(x), splitByChar(',', coalesce(Categories, ''))) AS beer_type,
    'wine1_raw' AS source,
    arrayMap(x -> trimBoth(x), splitByChar(',', coalesce(`Tasting Notes`, ''))) AS tasting_notes,
    [] AS base_ingredient
FROM t
WHERE Name NOT LIKE '$%' 
  AND Brand NOT LIKE '$%';

## ШАГ 5. beer_raw DONE

INSERT INTO tmp.flat_drinks_lake
WITH w AS (
SELECT * 
FROM default.beer_raw
), o AS (
SELECT wine
FROM tmp.flat_drinks_lake 
), t AS (
SELECT w.* 
FROM w
LEFT JOIN o
ON w.Name = o.wine
WHERE o.wine IS NULL
), 
(SELECT coalesce(max(id), 0) FROM tmp.flat_drinks_lake) AS max_id
SELECT
    CAST(max_id + rowNumberInAllBlocks() + 1 AS UInt32) AS id,
    Name AS wine,
    Description AS review,
    Brand AS winery,
    NULL AS designation,
    'Beer' AS category,
    Type AS subcategory,
    NULL AS site,
    NULL AS subregion,
    NULL AS region,
    multiIf(trimBoth(Country) IN ('US', 'USA', 'United States', 'United States of America'), 'US', nullIf(trimBoth(Country), '')) AS country,
    NULL AS glassware,
    NULL AS scale,
    NULL AS body,
    NULL AS abv,
    NULL AS years_aged,
    [] AS varietals,
    arrayMap(x -> trimBoth(replaceRegexpAll(replaceAll(x, '\t', ' '), '\\s+', ' ')), splitByChar(',', coalesce(`Food Pairing`, ''))) AS foods,
    arrayMap(x -> trimBoth(replaceRegexpAll(replaceAll(x, '\t', ' '), '\\s+', ' ')), splitByChar(',', coalesce(Categories, ''))) AS beer_type,
    'beer_raw' AS source,
    arrayMap(x -> trimBoth(replaceRegexpAll(replaceAll(x, '\t', ' '), '\\s+', ' ')), splitByChar(',', coalesce(`Tasting Notes`, ''))) AS tasting_notes,
    [] AS base_ingredient
FROM t
WHERE Name NOT LIKE '$%' 
  AND Brand NOT LIKE '$%';

## ШАГ 6. spirits_raw DONE

INSERT INTO tmp.flat_drinks_lake
WITH w AS (
SELECT * 
FROM default.spirits_raw
), o AS (
SELECT wine
FROM tmp.flat_drinks_lake 
), t AS (
SELECT w.* 
FROM w
LEFT JOIN o
ON w.Name = o.wine
WHERE o.wine IS NULL
), (SELECT coalesce(max(id), 0) FROM tmp.flat_drinks_lake) AS max_id
SELECT
    CAST(max_id + rowNumberInAllBlocks() + 1 AS UInt32) AS id,
    Name AS wine,
    Description AS review,
    Brand AS winery,
    NULL AS designation,
    NULL AS category,
    NULL AS subcategory,
    NULL AS site,
    NULL AS subregion,
    NULL AS region,
    multiIf(trimBoth(Country) IN ('US', 'USA', 'United States', 'United States of America'), 'US', nullIf(trimBoth(Country), '')) AS country,
    NULL AS glassware,
    NULL AS scale,
    NULL AS body,
    NULL AS abv,
    `Years Aged` AS years_aged,
    [] AS varietals,
    [] AS foods,
    -- Складываем весь сырой массив категорий "как есть" в beer_type для последующего разбора
    arrayMap(x -> trimBoth(x), splitByChar(',', coalesce(Categories, ''))) AS beer_type,
    'spirits_raw' AS source,
    arrayMap(x -> trimBoth(x), splitByChar(',', coalesce(`Tasting Notes`, ''))) AS tasting_notes,
    arrayMap(x -> trimBoth(x), splitByChar(',', coalesce(`Base Ingredient`, ''))) AS base_ingredient
FROM default.spirits_raw
WHERE Name NOT LIKE '$%' 
  AND Brand NOT LIKE '$%';

## основная таблица tmp.flat_drinks_lake
SHOW tmp.flat_drinks_lake
### есть дубликаты 3901 шт - РАЗОБРАТЬСЯ
SELECT wine, COUNT()
FROM tmp.flat_drinks_lake 
GROUP BY wine
HAVING COUNT()>1

# СЛИВ В pg_... insert, ДОБАВЛЕНИЕ В pg постоянно. MAPPING (CH_NAME, PG_ID)

## COUNTRIES
DROP VIEW IF EXISTS tmp.v_countries_map;
CREATE VIEW tmp.v_countries_map AS
SELECT DISTINCT
    fdl.country, 
    pc.id as id
FROM tmp.flat_drinks_lake AS fdl
LEFT JOIN tmp.pg_countries AS pc 
    ON pc.name = transform(fdl.country, 
        ['US', 'Republic of Georgia', 'Republic of Macedonia', 'Russia', 'Vietnamese'], 
        ['United States', 'Georgia', 'North Macedonia', 'Russian Federation', 'Vietnam'], 
        fdl.country
    );

## REGIONS
### слив во временную таблицу pg
INSERT INTO FUNCTION postgresql('pg_dev:5432', 'wine_db', 'region_insert', 'wine', 'wine1')
(name, country_id)
WITH o AS (
    SELECT country, region
    FROM tmp.flat_drinks_lake
    GROUP BY country, region
), p AS (
    SELECT 
        cv.id as country_id, 
        region,
        replaceRegexpAll(normalizeUTF8NFD(lowerUTF8(coalesce(region, 'dump_r'))), '([̀-ͯ])', '') as norm_name
    FROM o
    LEFT JOIN tmp.v_countries_map AS cv
    ON o.country = cv.country
), pg AS (
    SELECT 
        id, 
        country_id, 
        replaceRegexpAll(normalizeUTF8NFD(lowerUTF8(coalesce(name, 'dump_r'))), '([̀-ͯ])', '') as norm_name
    FROM tmp.pg_regions
)
SELECT p.region, p.country_id
FROM p
LEFT JOIN pg
    ON p.country_id = pg.country_id 
   AND p.norm_name = pg.norm_name
WHERE pg.id = 0 AND p.country_id > 0;

###  добавление в таблицу regions
docker compose exec -i wine_host psql -U wine -d wine_db -c "
INSERT INTO regions (name, country_id)
SELECT name, country_id 
FROM region_insert;
"
### mapping
CREATE VIEW tmp.v_regions_map AS
WITH 
-- Шаг 1: Получаем уникальные пары регион-страна из озера
lake_distinct AS (
    SELECT region, country
    FROM tmp.flat_drinks_lake
    GROUP BY region, country
),

-- Шаг 2: Привязываем country_id и нормализуем имя региона для джойна
lake_normalized AS (
    SELECT 
        ld.region AS name,
        cv.id AS country_id,
        replaceRegexpAll(normalizeUTF8NFD(lowerUTF8(coalesce(ld.region, 'dump_r'))), '([̀-ͯ])', '') AS norm_name
    FROM lake_distinct AS ld
    LEFT JOIN tmp.v_countries_map AS cv 
        ON ld.country = cv.country
),

-- Шаг 3: Нормализуем имена регионов из зеркала Postgres
pg_normalized AS (
    SELECT 
        id,
        country_id,
        replaceRegexpAll(normalizeUTF8NFD(lowerUTF8(coalesce(name, 'dump_r'))), '([̀-ͯ])', '') AS norm_name
    FROM tmp.pg_regions
)

-- Шаг 4: Соединяем по составному ключу (country_id + norm_name)
SELECT 
    pg.id AS id,
    ln.name AS name,
    ln.country_id AS country_id
FROM lake_normalized AS ln
LEFT JOIN pg_normalized AS pg
    ON ln.country_id = pg.country_id 
   AND ln.norm_name = pg.norm_name;

## SUBREGION
### слив во временную таблицу pg
INSERT INTO FUNCTION postgresql('pg_dev:5432', 'wine_db', 'subregion_insert', 'wine', 'wine1')
(name, region_id)
WITH c1 AS (
SELECT DISTINCT country_id, reg, name, sub FROM (
SELECT p.id AS country_id, 
l.reg AS reg,
l.subregion AS name, l.sub AS sub
FROM (SELECT DISTINCT country, 
                      coalesce(region, 'dump') AS reg,
                      coalesce(subregion, 'dump') AS sub,
                      subregion
      FROM tmp.flat_drinks_lake WHERE country IS NOT NULL) AS l
JOIN tmp.v_countries_map AS p
ON l.country = p.name
)), c2 AS (
SELECT  
p.id AS region_id, c1.name as name, c1.sub
FROM c1
JOIN tmp.v_regions_map AS p
ON reg = coalesce(p.name,'dump')  
AND c1.country_id = p.country_id
) 
SELECT c2.name AS name, c2.region_id AS region_id
FROM c2
LEFT JOIN postgresql('pg_dev:5432', 'wine_db', 'subregions', 'wine', 'wine1') AS sr
ON unaccent(c2.sub) = unaccent(coalesce(sr.name, 'dump'))
AND c2.region_id = sr.region_id
WHERE sr.id = 0
ORDER BY id, name, region_id;


### добавление в таблицу subregions
docker compose exec -i wine_host psql -U wine -d wine_db -c "
INSERT INTO subregions (name, region_id)
SELECT name, region_id 
FROM subregion_insert;
"
### mapping
CREATE VIEW tmp.v_subregions_map AS
WITH 
-- Шаг 1: Получаем уникальные комбинации субрегиона, региона и страны из озера
lake_distinct AS (
    SELECT subregion, region, country
    FROM tmp.flat_drinks_lake
    GROUP BY subregion, region, country
),

-- Шаг 2: Плоско подтягиваем country_id, чтобы избежать коллизий одноименных регионов
lake_with_country AS (
    SELECT 
        ld.subregion,
        ld.region,
        cm.id AS country_id
    FROM lake_distinct AS ld
    LEFT JOIN tmp.v_countries_map AS cm ON ld.country = cm.country
),

-- Шаг 3: Безопасно привязываем region_id и нормализуем имя субрегиона
lake_normalized AS (
    SELECT 
        lwc.subregion AS name,
        rm.id AS region_id,
        replaceRegexpAll(normalizeUTF8NFD(lowerUTF8(coalesce(lwc.subregion, 'dump_r'))), '([̀-ͯ])', '') AS norm_name
    FROM lake_with_country AS lwc
    LEFT JOIN tmp.v_regions_map AS rm 
        ON lwc.region = rm.name
       AND lwc.country_id = rm.country_id
),

-- Шаг 4: Нормализуем имена из зеркала субрегионов Postgres
pg_normalized AS (
    SELECT 
        id,
        region_id,
        replaceRegexpAll(normalizeUTF8NFD(lowerUTF8(coalesce(name, 'dump_r'))), '([̀-ͯ])', '') AS norm_name
    FROM tmp.pg_subregions
)

-- Шаг 5: Финальный безопасный маппинг
SELECT 
    pg.id AS id,
    ln.name AS name,
    ln.region_id AS region_id
FROM lake_normalized AS ln
LEFT JOIN pg_normalized AS pg
    ON ln.region_id = pg.region_id 
   AND ln.norm_name = pg.norm_name;

## SITE
### слив в pg
INSERT INTO FUNCTION postgresql('pg_dev:5432', 'wine_db', 'site_insert', 'wine', 'wine1')
(name, subregion_id)
WITH c1 AS (
SELECT DISTINCT country_id, reg, sub, site, name FROM (
SELECT p.id AS country_id, 
l.reg AS reg,
l.sub AS sub,
l.dsite AS site,
l.name AS name
FROM (SELECT DISTINCT country, 
                      coalesce(region, 'dump') AS reg,
                      coalesce(subregion, 'dump') AS sub,
                      site AS name,
                      coalesce(site, 'dump') AS dsite
      FROM tmp.flat_drinks_lake WHERE country IS NOT NULL) AS l
JOIN tmp.v_countries_map AS p
ON l.country = p.name
)), c2 AS (
SELECT  
p.id AS region_id, 
c1.name as name,
c1.site as site,
c1.sub
FROM c1
JOIN tmp.v_regions_map AS p
ON reg = coalesce(p.name,'dump')  
AND c1.country_id = p.country_id
), c3 AS ( 
SELECT sr.id AS subregion_id, 
c2.name AS name,
c2.region_id AS region_id,
c2.site as site,
c2.sub
FROM c2
JOIN postgresql('pg_dev:5432', 'wine_db', 'subregions', 'wine', 'wine1') AS sr
ON unaccent(c2.sub) = unaccent(coalesce(sr.name, 'dump'))
AND c2.region_id = sr.region_id
ORDER BY id, name, region_id
)
SELECT 
--si.id as id,
c3.name as name, 
c3.subregion_id as subregion_id
FROM c3
LEFT JOIN postgresql('pg_dev:5432', 'wine_db', 'sites', 'wine', 'wine1') AS si
ON unaccent(c3.site) = unaccent(coalesce(si.name, 'dump'))
AND c3.subregion_id = si.subregion_id
WHERE si.id = 0 

### добавление в таблицу sites
docker compose exec -i wine_host psql -U wine -d wine_db -c "
INSERT INTO sites (name, subregion_id)
SELECT name, subregion_id 
FROM site_insert;
"
### mapping
CREATE VIEW tmp.v_sites_map AS
WITH 
-- Шаг 1: Уникальные комбинации всей цепочки из озера
lake_distinct AS (
    SELECT site, subregion, region, country
    FROM tmp.flat_drinks_lake
    GROUP BY site, subregion, region, country
),

-- Шаг 2: Подтягиваем country_id
lake_with_country AS (
    SELECT ld.site, ld.subregion, ld.region, cm.id AS country_id
    FROM lake_distinct AS ld
    LEFT JOIN tmp.v_countries_map AS cm ON ld.country = cm.country
),

-- Шаг 3: Подтягиваем region_id
lake_with_region AS (
    SELECT lwc.site, lwc.subregion, rm.id AS region_id
    FROM lake_with_country AS lwc
    LEFT JOIN tmp.v_regions_map AS rm 
        ON lwc.region = rm.name 
       AND lwc.country_id = rm.country_id
),

-- Шаг 4: Привязываем subregion_id и нормализуем имя сайта
lake_normalized AS (
    SELECT 
        lwr.site AS name,
        sm.id AS subregion_id,
        replaceRegexpAll(normalizeUTF8NFD(lowerUTF8(coalesce(lwr.site, 'dump_r'))), '([̀-ͯ])', '') AS norm_name
    FROM lake_with_region AS lwr
    LEFT JOIN tmp.v_subregions_map AS sm 
        ON lwr.subregion = sm.name 
       AND lwr.region_id = sm.region_id
),

-- Шаг 5: Нормализуем имена из зеркала сайтов Postgres
pg_normalized AS (
    SELECT 
        id,
        subregion_id,
        replaceRegexpAll(normalizeUTF8NFD(lowerUTF8(coalesce(name, 'dump_r'))), '([̀-ͯ])', '') AS norm_name
    FROM tmp.pg_sites
)

-- Шаг 6: Финальный безопасный маппинг
SELECT 
    pg.id AS id,
    ln.name AS name,
    ln.subregion_id AS subregion_id
FROM lake_normalized AS ln
LEFT JOIN pg_normalized AS pg
    ON ln.subregion_id = pg.subregion_id 
   AND ln.norm_name = pg.norm_name
WHERE id != 0;

## VARIETALS
### слив во временную таблицу pg ...insert
INSERT INTO FUNCTION postgresql('pg_dev:5432', 'wine_db', 'varietal_insert', 'wine', 'wine1')
(name)

WITH 
-- 1. Разворачиваем массивы в плоские строки с помощью arrayJoin
lake_unnested AS (
    SELECT arrayJoin(varietals) AS single_varietal
    FROM tmp.flat_drinks_lake
),

-- 2. Группируем уникальные значения и нормализуем их
lake_distinct AS (
    SELECT 
        single_varietal,
        -- Если массив пустой или содержит пустую строку, coalesce подстрахует до 'dump_r'
        replaceRegexpAll(normalizeUTF8NFD(lowerUTF8(coalesce(nullIf(single_varietal, ''), 'dump_r'))), '([̀-ͯ])', '') AS norm_name
    FROM lake_unnested
    GROUP BY single_varietal
),

-- 3. Получаем данные из зеркала Postgres для проверки дубликатов
pg AS (
    SELECT 
        id, 
        replaceRegexpAll(normalizeUTF8NFD(lowerUTF8(coalesce(name, 'dump_r'))), '([̀-ͯ])', '') AS norm_name
    FROM tmp.pg_varietals
)

-- 4. Отфильтровываем то, что уже есть в базе, и отправляем в Postgres
SELECT 
    nullIf(ld.single_varietal, '') AS name
FROM lake_distinct AS ld
LEFT JOIN pg ON ld.norm_name = pg.norm_name
WHERE pg.id = 0
AND name NOT LIKE '$%'
;

### добавление в постояную таблицу pg
docker compose exec -i wine_host psql -U wine -d wine_db -c "
INSERT INTO varietals (name)
SELECT name 
FROM varietal_insert;
"
### маппинг


## FOODS
### слив во временную таблицу pg ...insert
INSERT INTO FUNCTION postgresql('pg_dev:5432', 'wine_db', 'food_insert', 'wine', 'wine1')
(name)

WITH 
-- 1. Разворачиваем массивы в плоские строки
lake_unnested AS (
    SELECT arrayJoin(foods) AS single_food
    FROM tmp.flat_drinks_lake
),

-- 2. Схлопываем пробелы и уникализируем уже ОЧИЩЕННЫЕ строки
lake_distinct AS (
    SELECT 
        -- Схлопываем множественные пробелы в один
        replaceRegexpAll(coalesce(nullIf(single_food, ''), 'dump_r'), ' +', ' ') AS clean_food,
        -- Строим нормализованное имя для точного джойна
        replaceRegexpAll(normalizeUTF8NFD(lowerUTF8(clean_food)), '([̀-ͯ])', '') AS norm_name
    FROM lake_unnested
    -- Группируем по clean_food, чтобы убрать дубликаты 'Vanilla Caramel' на этом этапе
    GROUP BY clean_food
),

-- 3. Получаем данные из зеркала Postgres (чистим пробелы на всякий случай)
pg AS (
    SELECT 
        id, 
        replaceRegexpAll(normalizeUTF8NFD(lowerUTF8(replaceRegexpAll(coalesce(name, 'dump_r'), ' +', ' '))), '([̀-ͯ])', '') AS norm_name
    FROM tmp.pg_foods
)

-- 4. Фильтруем дубликаты и исключаем пустые маркеры
SELECT 
    ld.clean_food AS name
FROM lake_distinct AS ld
LEFT JOIN pg ON ld.norm_name = pg.norm_name
WHERE pg.id = 0 
  -- Защита: не пускаем пустые значения в Postgres
  AND ld.clean_food != 'dump_r';

### добавление в постояную таблицу pg
docker compose exec -i wine_host psql -U wine -d wine_db -c "
INSERT INTO foods (name)
SELECT name 
FROM food_insert;
"
### маппинг


## TASTING_NOTES
### слив во временную таблицу pg ...insert
INSERT INTO FUNCTION postgresql('pg_dev:5432', 'wine_db', 'tastingnote_insert', 'wine', 'wine1')
(name)

WITH 
lake_unnested AS (
    SELECT arrayJoin(tasting_notes) AS single_note
    FROM tmp.flat_drinks_lake
),
lake_distinct AS (
    SELECT 
        replaceRegexpAll(coalesce(nullIf(single_note, ''), 'dump_r'), ' +', ' ') AS clean_note,
        replaceRegexpAll(normalizeUTF8NFD(lowerUTF8(clean_note)), '([̀-ͯ])', '') AS norm_name
    FROM lake_unnested
    GROUP BY clean_note
),
pg AS (
    SELECT 
        id, 
        replaceRegexpAll(normalizeUTF8NFD(lowerUTF8(replaceRegexpAll(coalesce(name, 'dump_r'), ' +', ' '))), '([̀-ͯ])', '') AS norm_name
    FROM tmp.pg_tastingnotes
)
SELECT 
    ld.clean_note AS name
FROM lake_distinct AS ld
LEFT JOIN pg ON ld.norm_name = pg.norm_name
WHERE pg.id = 0 
  AND ld.clean_note != 'dump_r';
### добавление в постояную таблицу pg
docker compose exec -i wine_host psql -U wine -d wine_db -c "
INSERT INTO tastingnotes (name)
SELECT name 
FROM tastingnote_insert;
"
### маппинг


## BASE INGREDIENT
### слив во временную таблицу pg ...insert
INSERT INTO FUNCTION postgresql('pg_dev:5432', 'wine_db', 'baseingredients_insert', 'wine', 'wine1')
(name)

WITH 
lake_unnested AS (
    SELECT arrayJoin(base_ingredient) AS single_ingr
    FROM tmp.flat_drinks_lake
),
lake_distinct AS (
    SELECT 
        replaceRegexpAll(coalesce(nullIf(single_ingr, ''), 'dump_r'), ' +', ' ') AS clean_ingr,
        replaceRegexpAll(normalizeUTF8NFD(lowerUTF8(clean_ingr)), '([̀-ͯ])', '') AS norm_name
    FROM lake_unnested
    GROUP BY clean_ingr
),
pg AS (
    SELECT 
        id, 
        replaceRegexpAll(normalizeUTF8NFD(lowerUTF8(replaceRegexpAll(coalesce(name, 'dump_r'), ' +', ' '))), '([̀-ͯ])', '') AS norm_name
    FROM tmp.pg_baseingredients
)
SELECT 
    ld.clean_ingr AS name
FROM lake_distinct AS ld
LEFT JOIN pg ON ld.norm_name = pg.norm_name
WHERE pg.id = 0 
  AND ld.clean_ingr != 'dump_r';

### добавление в постояную таблицу pg
docker compose exec -i wine_host psql -U wine -d wine_db -c "
INSERT INTO baseingredients (name)
SELECT name 
FROM baseingredients_insert;
"
### маппинг


-------NEW WAY-----------

## DESIGNATIONS внимание храним в PARCELS postgresql 
### слив во временную таблицу pg ...insert
INSERT INTO FUNCTION postgresql('pg_dev:5432', 'wine_db', 'designation_insert', 'wine', 'wine1')
(name)
WITH o AS (
    SELECT any(designation) AS name
    FROM tmp.flat_drinks_lake
    WHERE designation IS NOT NULL
    GROUP BY unaccent(designation)
), pg AS (
    SELECT id, name FROM postgresql('pg_dev:5432', 'wine_db', 'parcels', 'wine', 'wine1')
) 
SELECT o.name
FROM o
LEFT JOIN pg
ON unaccent_text(o.name) = unaccent(pg.name)
WHERE pg.id = 0;

### добавление в постояную таблицу pg PARCELS
docker compose exec -i wine_host psql -U wine -d wine_db -c "
INSERT INTO parcels (name)
SELECT name 
FROM designation_insert;
"
### маппинг


## CATEGORIES ДОДЕЛАТЬ
### слив во временную таблицу pg ...insert
### добавление в постояную таблицу pg
### маппинг

## SUBCATEGORIES ДОДЕЛАТЬ
см 02.1.SUBCATEGORIES.md
### слив во временную таблицу pg ...insert
### добавление в постояную таблицу pg
### маппинг 

## GLASSWARE
### слив во временную таблицу pg ...insert
INSERT INTO FUNCTION postgresql('pg_dev:5432', 'wine_db', 'glassware_insert', 'wine', 'wine1')
(name)
WITH o AS (
    SELECT any(glassware) AS name
    FROM tmp.flat_drinks_lake
    WHERE glassware IS NOT NULL
    GROUP BY unaccent(glassware)
), pg AS (
    SELECT id, name FROM postgresql('pg_dev:5432', 'wine_db', 'glasswares', 'wine', 'wine1')
) 
SELECT o.name
FROM o
LEFT JOIN pg
ON unaccent_text(o.name) = unaccent(pg.name)
WHERE pg.id = 0;

### добавление в постояную таблицу pg
docker compose exec -i wine_host psql -U wine -d wine_db -c "
INSERT INTO glasswares (name)
SELECT name 
FROM glassware_insert;
"


## SCALE
### слив во временную таблицу pg ...insert
INSERT INTO FUNCTION postgresql('pg_dev:5432', 'wine_db', 'scale_insert', 'wine', 'wine1')
(name)
WITH o AS (
    SELECT any(scale) AS name
    FROM tmp.flat_drinks_lake
    WHERE scale IS NOT NULL
    GROUP BY unaccent(scale)
), pg AS (
    SELECT id, name FROM postgresql('pg_dev:5432', 'wine_db', 'scales', 'wine', 'wine1')
) 
SELECT o.name
FROM o
LEFT JOIN pg
ON unaccent_text(o.name) = unaccent(pg.name)
WHERE pg.id = 0;
### добавление в постояную таблицу pg
docker compose exec -i wine_host psql -U wine -d wine_db -c "
INSERT INTO scales (name)
SELECT name 
FROM scale_insert;
"
### маппинг


## BODY
### слив во временную таблицу pg ...insert
INSERT INTO FUNCTION postgresql('pg_dev:5432', 'wine_db', 'body_insert', 'wine', 'wine1')
(name)
WITH o AS (
    SELECT any(body) AS name
    FROM tmp.flat_drinks_lake
    WHERE body IS NOT NULL
    GROUP BY unaccent(body)
), pg AS (
    SELECT id, name FROM postgresql('pg_dev:5432', 'wine_db', 'bodies', 'wine', 'wine1')
) 
SELECT o.name
FROM o
LEFT JOIN pg
ON unaccent_text(o.name) = unaccent(pg.name)
WHERE pg.id = 0;

### добавление в постояную таблицу pg
docker compose exec -i wine_host psql -U wine -d wine_db -c "
INSERT INTO bodies (name)
SELECT name 
FROM body_insert;
"

### маппинг


## WINERY
### слив во временную таблицу pg ...insert
INSERT INTO FUNCTION postgresql('pg_dev:5432', 'wine_db', 'winery_insert', 'wine', 'wine1')
(name)
WITH o AS (
    SELECT any(winery) AS name
    FROM tmp.flat_drinks_lake
    WHERE winery IS NOT NULL
    GROUP BY unaccent(winery)
), pg AS (
    SELECT id, name FROM postgresql('pg_dev:5432', 'wine_db', 'producers', 'wine', 'wine1')
) 
SELECT o.name
FROM o
LEFT JOIN pg
ON unaccent_text(o.name) = unaccent(pg.name)
WHERE pg.id = 0;

### добавление в постояную таблицу pg
docker compose exec -i wine_host psql -U wine -d wine_db -c "
INSERT INTO producers (name)
SELECT name 
FROM winery_insert;
"
### маппинг


#  далее см. 03_POSTGRES_SIDE.md