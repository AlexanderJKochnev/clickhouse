# наполнение справочников в postgresql данными из ch
1. наполнение производится в х этапов
   1. создание временной таблиц в postgresql (см. 01_...md последний пункт)
   2. создание зеркальных view в CH (см. 01_...md)
   3. наполнение озера рыбой tmp.flat_drinks_lake (см. 02_...md)
   4. создание новых таблиц:
      1. glassware
      2. scale
      3. body
      4. tasting_note
      5. base_ingridient
   5. запрос на выборку записей для справочников не имеющих подчиненных (geo, variteal, foods)
   6. запрос на наполнение синонимами не пополняемых справочников (category, subcategory)
   7. нормализация озера

## 5. запрос на выборку записей для справочников не имеющих подчиненных (geo, variteal, foods)
-- country
INSERT INTO FUNCTION postgresql('pg_dev:5432', 'wine_db', 'country_insert', 'wine', 'wine1')
(name)
WITH o AS (
SELECT country, 
CASE country
    WHEN 'US' THEN 'United States' 
    WHEN 'Republic of Georgia' THEN 'Georgia'
    WHEN 'Republic of Macedonia' THEN 'North Macedonia'
    WHEN 'Russia' THEN 'Russian Federation'
    WHEN 'Vietnamese' THEN 'Vietnam'
ELSE country
END AS name 
FROM tmp.flat_drinks_lake
GROUP BY country
), pc AS (
SELECT name, id, norm_name
FROM tmp.pg_countries
)
SELECT o.name
FROM o
LEFT JOIN pc
ON o.name = pc.name
WHERE id = 0
AND name IS NOT NULL
ORDER BY name, id













## ПРИЛОЖЕНИЯ

### очистка неудачных вставок
docker compose exec -i wine_host psql -U wine -d wine_db -c "
DELETE FROM sites
WHERE created_at >= '2026-05-31';
DELETE FROM subregions
WHERE created_at >= '2026-05-31';
DELETE FROM regions
WHERE created_at >= '2026-05-31';
"

# 0. скрипты для postrgresql 
## 0.1. очистка
docker compose exec -i wine_host psql -U wine -d wine_db -c "
-- очистка 
DROP TABLE IF EXISTS country_stagger, category_stagger, subcategory_stagger, region_stagger, subregion_stagger, 
site_stagger, varietal_stagger, food_stagger, designation_stagger,
country_insert, category_insert, subcategory_insert, region_insert, subregion_insert, 
site_insert, varietal_insert, food_insert, designation_insert;
DROP VIEW IF EXISTS v_categories_normalized, v_subcategories_normalized, v_countries_normalized, 
v_regions_normalized, v_subregions_normalized, v_sites_normalized, v_varietals_normalized, v_foods_normalized
"
## 0.2. скрипт создания запроса id, name, ch_id, parent_id; таблиц на обновление; таблиц на добавление
docker compose exec -i wine_host psql -U wine -d wine_db -c "
-- очистка 
DROP TABLE IF EXISTS country_insert, category_insert, subcategory_insert, region_insert, subregion_insert, 
site_insert, varietal_insert, food_insert, designation_insert;
--create table
CREATE TABLE country_insert (name VARCHAR(255));
CREATE TABLE region_insert (name VARCHAR(255), country_id INTEGER);
CREATE TABLE subregion_insert (name VARCHAR(255), region_id INTEGER);
CREATE TABLE site_insert (name VARCHAR(255), subregion_id INTEGER);
CREATE TABLE category_insert (name VARCHAR(255));
CREATE TABLE subcategory_insert (name VARCHAR(255), category_id INTEGER);
CREATE TABLE food_insert (name VARCHAR(255));
CREATE TABLE varietal_insert (name VARCHAR(255));
CREATE TABLE designation_insert (name VARCHAR(255));
"

# 1. скрипты для clickhouse (сравнивают pg и ch и добавляют в pg)
-- COUNTRIES
INSERT INTO FUNCTION postgresql('pg_dev:5432', 'wine_db', 'country_insert', 'wine', 'wine1')
(name)
WITH c as (
SELECT id, name, norm_key
FROM postgresql('pg_dev', 'wine_db', 'v_countries_normalized', 'wine', 'wine1') AS c
), ch as (
SELECT id, 
CASE name
    WHEN 'US' THEN 'United States' 
    WHEN 'Republic of Georgia' THEN 'Georgia'
    WHEN 'Republic of Macedonia' THEN 'North Macedonia'
    WHEN 'Russia' THEN 'Russian Federation'
    WHEN 'Vietnamese' THEN 'Vietnam'
ELSE name
END AS name1,
name
FROM pg_country
ORDER BY name
)
SELECT ch.name 
FROM ch
LEFT JOIN c
ON ch.name1 = c.name
WHERE c.id IS NULL AND ch.name IS NOT NULL;

-- выполнить 2.1. ниже затем продолжать


--make country_map
DROP TABLE IF EXISTS tmp.country_map; 
CREATE TABLE tmp.country_map AS
WITH c as (
SELECT id, name, norm_key, ch_id
FROM postgresql('pg_dev', 'wine_db', 'v_countries_normalized', 'wine', 'wine1') AS c
), ch as (
SELECT id, 
CASE name
    WHEN 'US' THEN 'United States' 
    WHEN 'Republic of Georgia' THEN 'Georgia'
    WHEN 'Republic of Macedonia' THEN 'North Macedonia'
    WHEN 'Russia' THEN 'Russian Federation'
    WHEN 'Vietnamese' THEN 'Vietnam'
ELSE name
END AS name1,
name
FROM pg_country
ORDER BY name
)
SELECT ch.name, ch.id as ch_id, c.id as pg_id 
FROM ch
JOIN c
ON ch.name1 = c.name
WHERE ch.name IS NOT NULL
ORDER BY pg_id;

--regions
INSERT INTO FUNCTION postgresql('pg_dev:5432', 'wine_db', 'region_insert', 'wine', 'wine1')
(name, country_id)
WITH pgr as (
SELECT id, coalesce(name, 'dump') as name, coalesce(norm_key, 'dump') as norm_key, country_id
FROM postgresql('pg_dev', 'wine_db', 'v_regions_normalized', 'wine', 'wine1') AS c
), chr0 as (
SELECT id, name, country_id
FROM pg_region
), cmp as (
SELECT pg_id, ch_id
FROM tmp.country_map
), chr1 as (
SELECT chr0.id, coalesce(name, 'dump') as name, cmp.pg_id as country_id
FROM chr0 
JOIN cmp ON chr0.country_id = cmp.ch_id
ORDER BY name
)
SELECT CASE chr1.name
            WHEN 'dump' THEN Null
            ELSE chr1.name END AS name, 
            chr1.country_id
FROM chr1
LEFT JOIN pgr ON chr1.country_id = pgr.country_id
-- AND chr1.name = pgr.name
WHERE replaceRegexpAll(normalizeUTF8NFD(lowerUTF8(chr1.name)), '([\\x{0300}-\\x{036F}])', '') = pgr.norm_key
AND pgr.id IS NULL

-- выполнить 2.2. ниже затем продолжать

--make region_map
DROP TABLE IF EXISTS tmp.region_map; 
CREATE TABLE tmp.region_map AS
WITH pgr as (
SELECT id, coalesce(name, 'dump') as name, coalesce(norm_key, 'dump') as norm_key, country_id
FROM postgresql('pg_dev', 'wine_db', 'v_regions_normalized', 'wine', 'wine1') AS c
), chr0 as (
SELECT id, name, country_id
FROM pg_region
), cmp as (
SELECT pg_id, ch_id
FROM tmp.country_map
), chr1 as (
SELECT chr0.id, coalesce(name, 'dump') as name, cmp.pg_id as country_id
FROM chr0 
JOIN cmp ON chr0.country_id = cmp.ch_id
ORDER BY name
)
SELECT CASE chr1.name
            WHEN 'dump' THEN Null
            ELSE chr1.name END AS name, 
            chr1.id as ch_id,
            pgr.id as pg_id,
            pgr.country_id as pg_country_id
FROM chr1
LEFT JOIN pgr ON chr1.country_id = pgr.country_id
-- AND chr1.name = pgr.name
WHERE replaceRegexpAll(normalizeUTF8NFD(lowerUTF8(chr1.name)), '([\\x{0300}-\\x{036F}])', '') = pgr.norm_key

--subregions
INSERT INTO FUNCTION postgresql('pg_dev:5432', 'wine_db', 'subregion_insert', 'wine', 'wine1')
(name, region_id)
WITH pgr as (
SELECT id, coalesce(name, 'dump') as name, coalesce(norm_key, 'dump') as norm_key, region_id
FROM postgresql('pg_dev', 'wine_db', 'v_subregions_normalized', 'wine', 'wine1') AS c
), chr0 as (
SELECT id, name, region_id
FROM pg_subregion
), cmp as (
SELECT pg_id, ch_id
FROM tmp.region_map
), chr1 as (
SELECT chr0.id, coalesce(name, 'dump') as name, cmp.pg_id as region_id
FROM chr0 
JOIN cmp ON chr0.region_id = cmp.ch_id
ORDER BY name
)
SELECT CASE chr1.name
            WHEN 'dump' THEN Null
            ELSE chr1.name END AS name, 
            -- pgr.name, pgr.id,            
            chr1.region_id
FROM chr1
LEFT JOIN pgr ON chr1.region_id = pgr.region_id
AND replaceRegexpAll(normalizeUTF8NFD(lowerUTF8(chr1.name)), '([\\x{0300}-\\x{036F}])', '') = pgr.norm_key
WHERE pgr.id IS NULL
ORDER BY name

-- выполнить 2.3. ниже затем продолжать

--make subregion_map
DROP TABLE IF EXISTS tmp.subregion_map; 
CREATE TABLE tmp.subregion_map AS
WITH pgr as (
SELECT id, coalesce(name, 'dump') as name, coalesce(norm_key, 'dump') as norm_key, region_id
FROM postgresql('pg_dev', 'wine_db', 'v_subregions_normalized', 'wine', 'wine1')
), chr0 as (
SELECT id, name, region_id
FROM pg_subregion
), cmp as (
SELECT pg_id, ch_id
FROM tmp.region_map
), chr1 as (
SELECT chr0.id, coalesce(name, 'dump') as name, cmp.pg_id as region_id
FROM chr0 
JOIN cmp ON chr0.region_id = cmp.ch_id
ORDER BY name
)
SELECT CASE chr1.name
            WHEN 'dump' THEN Null
            ELSE chr1.name END AS name, 
            -- pgr.name, pgr.id,
            chr1.id AS ch_id,    
            pgr.id AS pg_id,    
            chr1.region_id
FROM chr1
LEFT JOIN pgr ON chr1.region_id = pgr.region_id
WHERE (pgr.name = chr1.name OR
replaceRegexpAll(normalizeUTF8NFD(lowerUTF8(chr1.name)), '([\\x{0300}-\\x{036F}])', '') = pgr.norm_key)
-- AND pgr.id IS NULL
ORDER BY ch_id

--site
INSERT INTO FUNCTION postgresql('pg_dev:5432', 'wine_db', 'site_insert', 'wine', 'wine1')
(name, subregion_id)
WITH pgr as (
SELECT id, coalesce(name, 'dump') as name, coalesce(norm_key, 'dump') as norm_key, subregion_id
FROM postgresql('pg_dev', 'wine_db', 'v_sites_normalized', 'wine', 'wine1')
), chr0 as (
SELECT id, name, subregion_id
FROM pg_site
), cmp as (
SELECT pg_id, ch_id
FROM tmp.subregion_map
), chr1 as (
SELECT chr0.id, coalesce(name, 'dump') as name, cmp.pg_id as subregion_id
FROM chr0 
JOIN cmp ON chr0.subregion_id = cmp.ch_id
ORDER BY name
)
SELECT CASE chr1.name
            WHEN 'dump' THEN Null
            ELSE chr1.name END AS name, 
            -- pgr.name, pgr.id,            
            chr1.subregion_id
FROM chr1
LEFT JOIN pgr ON chr1.subregion_id = pgr.subregion_id
AND replaceRegexpAll(normalizeUTF8NFD(lowerUTF8(chr1.name)), '([\\x{0300}-\\x{036F}])', '') = pgr.norm_key
WHERE pgr.id IS NULL
ORDER BY name


# 2. скрипты PG - добавление справочников 
## 2.1. countries
docker compose exec -i wine_host psql -U wine -d wine_db -c "
INSERT INTO countries (name)
SELECT name 
FROM country_insert;
"

## 2.2. regions
docker compose exec -i wine_host psql -U wine -d wine_db -c "
INSERT INTO regions (name, country_id)
SELECT name, country_id 
FROM region_insert;
"

## 2.3. subregions
docker compose exec -i wine_host psql -U wine -d wine_db -c "
INSERT INTO subregions (name, region_id)
SELECT name, region_id 
FROM subregion_insert;
"


# ------------------------------------------------------
# 1. СОЗДАНИЕ ЗАПРОСОВ В PG для отображегния в CH
## CATEGORY
docker compose exec -i wine_host psql -U wine -d wine_db -c "
CREATE OR REPLACE VIEW v_categories_normalized AS
SELECT 
    id,
    name, 
    -- Вычисляем ключ на стороне Postgres. Индекс unaccent(lower(name)) здесь отлично поможет
    unaccent(lower(name)) AS norm_key,
    ch_id
FROM categories;
"
### проверка 

## SUBCATEGORIES
docker compose exec -i wine_host psql -U wine -d wine_db -c "
CREATE OR REPLACE VIEW v_subcategories_normalized AS
SELECT 
    id, 
    name,
    category_id,
    unaccent(lower(name)) AS norm_key,
    ch_id
FROM subcategories;
"

## COUNTRIES / REGIONS / SUBREGIONS / SITES
docker compose exec -i wine_host psql -U wine -d wine_db -c "
CREATE OR REPLACE VIEW v_countries_normalized AS
SELECT 
    id, 
    name,
    unaccent(lower(name)) AS norm_key,
    ch_id
FROM countries;

CREATE OR REPLACE VIEW v_regions_normalized AS
SELECT 
    id, 
    name,
    country_id,
    unaccent(lower(name)) AS norm_key,
    ch_id
FROM regions;

CREATE OR REPLACE VIEW v_subregions_normalized AS
SELECT 
    id, 
    name,
    region_id,
    unaccent(lower(name)) AS norm_key,
    ch_id
FROM subregions;

CREATE OR REPLACE VIEW v_sites_normalized AS
SELECT 
    id, 
    name,
    subregion_id,
    unaccent(lower(name)) AS norm_key,
    ch_id
FROM sites;
"

## PRODUCERS, VARIETALS, FOODS, DESIGNATIONS 
docker compose exec -i wine_host psql -U wine -d wine_db -c "
CREATE OR REPLACE VIEW v_producers_normalized AS
SELECT 
    id, 
    name,
    unaccent(lower(name)) AS norm_key,
    ch_id
FROM producers;

CREATE OR REPLACE VIEW v_varietals_normalized AS
SELECT 
    id, 
    name,
    unaccent(lower(name)) AS norm_key,
    ch_id
FROM varietals;

CREATE OR REPLACE VIEW v_foods_normalized AS
SELECT 
    id, 
    name,
    unaccent(lower(name)) AS norm_key,
    ch_id
FROM foods;

CREATE OR REPLACE VIEW v_designations_normalized AS
SELECT 
    id, 
    name,
    unaccent(lower(name)) AS norm_key,
    ch_id
FROM designations;
"


# 2. выполняется в clickhouse (создаем запросы для обновления и добавления данных в справочники)
## category

WITH c as (
SELECT id, name, norm_key, ch_id
FROM postgresql('pg_dev', 'wine_db', 'v_categories_normalized', 'wine', 'wine1') AS c
), ch as (
SELECT id, name
FROM pg_category
), cc AS (
SELECT c.id, c.name, ch.id, ch.name
FROM c
LEFT JOIN ch
ON c.name = ch.name
WHERE ch.id = 0
), (SELECT coalesce(max(id), 0) FROM default.pg_category) AS max_id
INSERT INTO pg_category
SELECT 
CAST(max_id + rowNumberInAllBlocks() + 1 AS UInt32) AS id,
cc.name
FROM cc

WITH c as (
SELECT id, name, norm_key, ch_id
FROM postgresql('pg_dev', 'wine_db', 'v_categories_normalized', 'wine', 'wine1') AS c
), ch as (
SELECT id, name
FROM pg_category
), cc as (
SELECT c.id, c.name, ch.id, ch.name
FROM c
JOIN ch
ON c.name = ch.name;
)
UPDATE

  ON replaceRegexpAll(normalizeUTF8NFD(lowerUTF8(lake.raw_name)), '([\\x{0300}-\\x{036F}])', '') = pg.norm_key
WHERE pg.id = 0;

## countries
-- UPDATE
DROP VIEW IF EXISTS tmp.country_upd; 
CREATE VIEW tmp.country_upd AS

WITH c as (
SELECT id, name, norm_key, ch_id
FROM postgresql('pg_dev', 'wine_db', 'v_countries_normalized', 'wine', 'wine1') AS c
), ch as (
SELECT id, 
CASE name
    WHEN 'US' THEN 'United States' 
    WHEN 'Republic of Georgia' THEN 'Georgia'
    WHEN 'Republic of Macedonia' THEN 'North Macedonia'
    WHEN 'Russia' THEN 'Russian Federation'
    WHEN 'Vietnamese' THEN 'Vietnam'
ELSE name
END AS name1,
name
FROM pg_country
ORDER BY name
)
SELECT ch.name 
FROM ch
LEFT JOIN c
ON ch.name1 = c.name
WHERE c.id IS NULL AND ch.name IS NOT NULL;


-- CREATE
DROP VIEW IF EXISTS tmp.category_ins;
CREATE VIEW tmp.category_ins AS
WITH c as (
SELECT id, name, norm_key, ch_id
FROM postgresql('pg_dev', 'wine_db', 'v_countries_normalized', 'wine', 'wine1') AS c
), ch as (
SELECT id, 
CASE name
    WHEN 'US' THEN 'United States' 
    WHEN 'Republic of Georgia' THEN 'Georgia'
    WHEN 'Republic of Macedonia' THEN 'North Macedonia'
    WHEN 'Russia' THEN 'Russian Federation'
ELSE name
END AS name
FROM pg_country
WHERE name != 'Vietnamese'
ORDER BY name
)
SELECT ch.id AS ch_id, ch.name
FROM ch
LEFT JOIN c
ON ch.name = c.name
WHERE c.id IS NULL;

## region

# 3. СОЗДАНИЕ ВРЕМЕННЫХ ТАБЛИЦ В PG для обновления справочников выполняется в postgresql
## создаем временные таблиы для обновления (запомнить и назабыть удалить!)
### country_stagger
docker compose exec -i wine_host psql -U wine -d wine_db -c "
CREATE TABLE country_stagger (
    id INTEGER,
    ch_id INTEGER
);
"
### region, subregion, site, category, subcategory, producer, varietal, food, destination
docker compose exec -i wine_host psql -U wine -d wine_db -c "
CREATE TABLE region_stagger (
    id INTEGER,
    ch_id INTEGER
);
CREATE TABLE subregion_stagger (
    id INTEGER,
    ch_id INTEGER
);
CREATE TABLE site_stagger (
    id INTEGER,
    ch_id INTEGER
);
CREATE TABLE category_stagger (
    id INTEGER,
    ch_id INTEGER
);
CREATE TABLE subcategory_stagger (
    id INTEGER,
    ch_id INTEGER
);
CREATE TABLE producer_stagger (
    id INTEGER,
    ch_id INTEGER
);
CREATE TABLE varietal_stagger (
    id INTEGER,
    ch_id INTEGER
);
CREATE TABLE food_stagger (
    id INTEGER,
    ch_id INTEGER
);
CREATE TABLE designation_stagger (
    id INTEGER,
    ch_id INTEGER
);
"

# 4. СОЗДАНИЕ ВРЕМЕННЫХ ТАБЛИЦ В PG для добавления в справочники
## не забыть удалить
docker compose exec -i wine_host psql -U wine -d wine_db -c "
CREATE TABLE country_insert (
    id INTEGER,
    name VARCHAR(255)
);
CREATE TABLE region_insert (
    id INTEGER,
    name VARCHAR(255)
);
CREATE TABLE subregion_insert (
    id INTEGER,
    name VARCHAR(255)
);
CREATE TABLE site_insert (
    id INTEGER,
    name VARCHAR(255)
);
CREATE TABLE category_insert (
    id INTEGER,
    name VARCHAR(255)
);
CREATE TABLE subcategory_insert (
    id INTEGER,
    name VARCHAR(255)
);
CREATE TABLE producer_insert (
    id INTEGER,
    name VARCHAR(255)
);
CREATE TABLE varietal_insert (
    id INTEGER,
    name VARCHAR(255)
);
CREATE TABLE food_insert (
    id INTEGER,
    name VARCHAR(255)
);
CREATE TABLE designation_insert (
    id INTEGER,
    name VARCHAR(255)
);
"




# 4. ЗАЛИВКА ДАННЫХ ДЛЯ ОБНОВЛЕНИЯ ВО ВРЕМЕННЫЕ ТАБЛИЦЫ (из CH)
## country
INSERT INTO FUNCTION postgresql('pg_dev:5432', 'wine_db', 'country_stagger', 'wine', 'wine1') 
(id, ch_id)
SELECT id, ch_id 
FROM tmp.country_upd

# 5. ОБНОВЛЕНИЕ ДАННЫХ В PG (поле ch_id)
docker compose exec -i wine_host psql -U wine -d wine_db -c "
UPDATE countries AS c
SET 
    ch_id = s.ch_id
FROM country_stagger AS s
WHERE c.id = s.id;
"

# 6. ДОБАВЛЕНИЕ НОВЫХ ДАННЫХ в PG (выполняется в ch)
INSERT INTO FUNCTION postgresql('pg_dev:5432', 'wine_db', 'countries', 'wine', 'wine1')
(ch_id, name)
SELECT 
    ch_id, name
FROM tmp.category_ins;
