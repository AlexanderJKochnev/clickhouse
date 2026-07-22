## создаем напрямую view из postgresql

## создание mirror view в CH
--CATEGORIES
DROP VIEW IF EXISTS tmp.pg_categories;
CREATE VIEW tmp.pg_categories AS
WITH pg AS (
SELECT id, name, arrayMap(x -> trimBoth(x), splitByChar(',', coalesce(description, ''))) AS synonims,
unaccent(name) AS norm_name
FROM postgresql('pg_dev', 'wine_db', 'categories', 'wine', 'wine1')
ORDER BY id
)
SELECT id, name,  
    arrayFilter(
        x -> x != '',  -- удаляем пустые строки
        arrayDistinct(
            arrayPushBack(synonims, name)  -- добавляем name и убираем дубликаты
        )
    ) AS synonims, 
    norm_name
FROM pg;

--SUBCATEGORIES
DROP VIEW IF EXISTS tmp.pg_subcategories;
CREATE VIEW tmp.pg_subcategories AS
WITH pg AS (
SELECT id, name, arrayMap(x -> trimBoth(x), splitByChar(',', coalesce(description, ''))) AS synonims,
unaccent(name) AS norm_name,
category_id
FROM postgresql('pg_dev', 'wine_db', 'subcategories', 'wine', 'wine1')
ORDER BY id
)
SELECT id, name,  
    arrayFilter(
        x -> x != '',  -- удаляем пустые строки
        arrayDistinct(
            arrayPushBack(synonims, name)  -- добавляем name и убираем дубликаты
        )
    ) AS synonims, 
    norm_name,
    category_id
FROM pg;

--COUNTRIES
DROP VIEW IF EXISTS tmp.pg_countries;
CREATE VIEW tmp.pg_countries AS
SELECT id, name, arrayMap(x -> trimBoth(x), splitByChar(',', coalesce(description, ''))) AS synonims,
unaccent(name) AS norm_name
FROM postgresql('pg_dev', 'wine_db', 'countries', 'wine', 'wine1')
ORDER BY id, name;

--REGIONS
DROP VIEW IF EXISTS tmp.pg_regions;
CREATE VIEW tmp.pg_regions AS
SELECT id, name, arrayMap(x -> trimBoth(x), splitByChar(',', coalesce(description, ''))) AS synonims,
unaccent(name) AS norm_name,
country_id
FROM postgresql('pg_dev', 'wine_db', 'regions', 'wine', 'wine1')
ORDER BY id;

--SUBREGIONS
DROP VIEW IF EXISTS tmp.pg_subregions;
CREATE VIEW tmp.pg_subregions AS
SELECT id, name, arrayMap(x -> trimBoth(x), splitByChar(',', coalesce(description, ''))) AS synonims,
unaccent(name) AS norm_name,
region_id
FROM postgresql('pg_dev', 'wine_db', 'subregions', 'wine', 'wine1')
ORDER BY id;

--SITES
DROP VIEW IF EXISTS tmp.pg_sites;
CREATE VIEW tmp.pg_sites AS
SELECT id, name, arrayMap(x -> trimBoth(x), splitByChar(',', coalesce(description, ''))) AS synonims,
unaccent(name) AS norm_name,
subregion_id
FROM postgresql('pg_dev', 'wine_db', 'sites', 'wine', 'wine1')
ORDER BY id;

--VARIETALS
DROP VIEW IF EXISTS tmp.pg_varietals;
CREATE VIEW tmp.pg_varietals AS
SELECT id, name, arrayMap(x -> trimBoth(x), splitByChar(',', coalesce(description, ''))) AS synonims,
unaccent(name) AS norm_name
FROM postgresql('pg_dev', 'wine_db', 'varietals', 'wine', 'wine1')
ORDER BY id, name;

--FOODS
DROP VIEW IF EXISTS tmp.pg_foods;
CREATE VIEW tmp.pg_foods AS
SELECT id, name, arrayMap(x -> trimBoth(x), splitByChar(',', coalesce(description, ''))) AS synonims,
unaccent(name) AS norm_name
FROM postgresql('pg_dev', 'wine_db', 'foods', 'wine', 'wine1')
ORDER BY id, name;

--DESIGNATIONS
DROP VIEW IF EXISTS tmp.pg_designations;
CREATE VIEW tmp.pg_designations AS
SELECT id, name, arrayMap(x -> trimBoth(x), splitByChar(',', coalesce(description, ''))) AS synonims,
unaccent_text(name) AS norm_name
FROM postgresql('pg_dev', 'wine_db', 'parcels', 'wine', 'wine1')
ORDER BY id, name;

--TASTING NOTE
DROP VIEW IF EXISTS tmp.pg_tastingnotes;
CREATE VIEW tmp.pg_tastingnotes AS
SELECT id, name, arrayMap(x -> trimBoth(x), splitByChar(',', coalesce(description, ''))) AS synonims,
unaccent(name) AS norm_name
FROM postgresql('pg_dev', 'wine_db', 'tastingnotes', 'wine', 'wine1')
ORDER BY id, name;

--BASE INGREDIENT
DROP VIEW IF EXISTS tmp.pg_baseingredients;
CREATE VIEW tmp.pg_baseingredients AS
SELECT id, name, arrayMap(x -> trimBoth(x), splitByChar(',', coalesce(description, ''))) AS synonims,
unaccent(name) AS norm_name
FROM postgresql('pg_dev', 'wine_db', 'baseingredients', 'wine', 'wine1')
ORDER BY id, name;

--GLASSWARE
DROP VIEW IF EXISTS tmp.pg_glasswares;
CREATE VIEW tmp.pg_glasswares AS
SELECT id, name, arrayMap(x -> trimBoth(x), splitByChar(',', coalesce(description, ''))) AS synonims,
unaccent(name) AS norm_name
FROM postgresql('pg_dev', 'wine_db', 'glasswares', 'wine', 'wine1')
ORDER BY id, name;

--SCALE
DROP VIEW IF EXISTS tmp.pg_scales;
CREATE VIEW tmp.pg_scales AS
SELECT id, name, arrayMap(x -> trimBoth(x), splitByChar(',', coalesce(description, ''))) AS synonims,
unaccent(name) AS norm_name
FROM postgresql('pg_dev', 'wine_db', 'scales', 'wine', 'wine1')
ORDER BY id, name;

--BODY
DROP VIEW IF EXISTS tmp.pg_bodies;
CREATE VIEW tmp.pg_bodies AS
SELECT id, name, arrayMap(x -> trimBoth(x), splitByChar(',', coalesce(description, ''))) AS synonims,
unaccent(name) AS norm_name
FROM postgresql('pg_dev', 'wine_db', 'bodies', 'wine', 'wine1')
ORDER BY id, name;
--

## создание в PG временных таблиц для добавления данных в справочники
docker compose exec -i wine_host psql -U wine -d wine_db -c "
-- очистка 
DROP TABLE IF EXISTS country_insert, category_insert, subcategory_insert, region_insert, subregion_insert, 
site_insert, varietal_insert, food_insert, designation_insert, tastingnote_insert, baseingredients_insert, 
glassware_insert, scale_insert, body_insert, winery_insert, drink_insert, drink_update
;
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
CREATE TABLE tastingnote_insert(name VARCHAR(255));
CREATE TABLE baseingredients_insert(name VARCHAR(255));
CREATE TABLE glassware_insert(name VARCHAR(255));
CREATE TABLE scale_insert(name VARCHAR(255));
CREATE TABLE body_insert(name VARCHAR(255));
CREATE TABLE winery_insert(name VARCHAR(255));
"
# далее см 02 NEW VISION.md


# примечания
##  получение элементов массива
WITH a AS (
SELECT DISTINCT arrayJoin(beer_type) AS element
FROM tmp.flat_drinks_lake
)
