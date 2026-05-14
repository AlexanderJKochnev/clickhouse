# ИМПОРТ ИЗ ТАБЛИЦЫ beverages_indexed
# 0. функция для преобразования странных букв (возможно придется выполнить при перезапуске)
CREATE OR REPLACE FUNCTION normalize_text AS (s) -> 
    replaceRegexpAll(
        lower(
            replaceRegexpAll(replaceRegexpAll(replaceRegexpAll(replaceRegexpAll(replaceRegexpAll(replaceRegexpAll(replaceRegexpAll(replaceRegexpAll(replaceRegexpAll(replaceRegexpAll(replaceRegexpAll(replaceRegexpAll(replaceRegexpAll(replaceRegexpAll(replaceRegexpAll(replaceRegexpAll(replaceRegexpAll(replaceRegexpAll(replaceRegexpAll(replaceRegexpAll(replaceRegexpAll(replaceRegexpAll(
                replaceRegexpAll(s, '-', ' '), 
            'ü', 'u'), 'ö', 'o'), 'ä', 'a'), 'ß', 'ss'), '[éèêë]', 'e'), '[àâãå]', 'a'), '[îï]', 'i'), '[ôõø]', 'o'), '[ûù]', 'u'), 'ç', 'c'), 'ñ', 'n'), '[á]', 'a'), '[í]', 'i'), '[ó]', 'o'), '[ú]', 'u'), 'æ', 'ae'), 'ł', 'l'), 'ń', 'n'), 'ś', 's'), 'ź', 'z'), 'ż', 'z'), '[^a-zA-Z0-9 ]', '')
        ), 
    ' {2,}', ' ');

# 1. материализованная таблица из postgresql 
SET allow_experimental_database_materialized_postgresql = 1;
CREATE DATABASE test_replica
ENGINE = MaterializedPostgreSQL(
    'wine_host:5432',
    'test_db',
    'wine',
    'wine1'
)
SETTINGS
    materialized_postgresql_tables_list = 'wordhashs(id, word, freq, mainword_id), mainwords(id, word)'; 

# 2. views NOT USED

CREATE VIEW default.beverages_words_active (`word` String, `freq` UInt32, `hash` Int64,)
AS
SELECT bw.word, bw.freq, bw.hash FROM default.beverages_words bw
LEFT OUTER JOIN test_replica.wordhashs tw ON bw.word = tw.word
WHERE tw.id == 0;

SELECT count() FROM default.beverages_words bw
LEFT OUTER JOIN test_replica.wordhashs tw ON bw.word = tw.word
WHERE tw.id == 0;

# НОРМАЛИЗАЦИЯ ТАБЛИЦЫ beverages_indexed
## JSON
SELECT DISTINCT 
    arrayJoin(JSONDynamicPaths(attributes)) AS key_name
FROM beverages_indexed

## !!! СОЗДАНИЕ ПЛОСКОЙ ТАБЛИЦЫ bev_flat
CREATE TABLE default.bev_flat (
`id` String,
`name` String,
`description` Nullable(String),
`category` String,
`brand` String,
`abv` Nullable(Float32),
`price` Nullable(Decimal(10, 2)),
`rating` Nullable(Float32),
`varietal` Array(String),
`country` String,
`region` Nullable(String),
`subregion` Nullable(String),
`site` Nullable(String),
`ibu` Nullable(String),
`whisky_category` Nullable(String),
`foods` Array(String))
ENGINE = MergeTree()
ORDER BY (id, name, brand, category, country)
AS
SELECT  id,
        name,
        concat(description, coalesce(concat(' Tasting notes: ', tasting_notes), '')) description, 
        category,
        brand,
        abv,
        price,
        rating,
        arrayFilter(
            x -> notEmpty(x), 
            arrayDistinct(
                splitByString(', ', coalesce(variety, varietal, ''))
            )
        ) varietal, 
        -- arrayDistinct(
        --     splitByString(', ', coalesce(variety, varietal, ''))) varietal,
        -- coalesce(variety, varietal) varietal, 
        coalesce(country, acountry) country, 
        coalesce(province, aprovince) region,
        coalesce(region_2, aregion_2) subregion,
        coalesce(region_1, aregion_1) site, 
        ibu, -- единица горечи пива UInt32
        whisky_category, 
        arrayFilter(
            x -> notEmpty(x), 
            arrayDistinct(
                splitByString(', ', coalesce(food_pairing, ''))
            )
        ) foods
FROM (
    SELECT *, 
        splitByString(', ', coalesce(appellation, '')) AS parts,
        length(parts) AS cnt,
        multiIf(
            cnt >= 4, parts[1],
            cnt >= 3, NULL,
            cnt >= 2, NULL,
            cnt >= 1, NULL,
            NULL
        ) AS aregion_1,
        multiIf(
            cnt >= 4, parts[2],
            cnt == 3, parts[1],
            cnt >= 2, NULL,
            NULL
        ) AS aregion_2,
        multiIf(
            cnt >= 4, parts[3],
            cnt == 3, parts[2],
            cnt == 2, parts[1],
            NULL
        ) AS aprovince,
        parts[cnt] AS acountry
    FROM (
        SELECT
            id,
            name,
            description,
            category,
            country,
            brand,
            abv,
            price,
            rating,            
            -- Разворачиваем JSON ключи с явным приведением типа в версии 26.4
            attributes.designation::Nullable(String)    AS designation,
            attributes.province::Nullable(String)       AS province,
            attributes.region_1::Nullable(String)       AS region_1,
            attributes.variety::Nullable(String)        AS variety,
            attributes.appellation::Nullable(String)    AS appellation,
            attributes.varietal::Nullable(String)       AS varietal,
            attributes.region_2::Nullable(String)       AS region_2,
            attributes.categories::Nullable(String)     AS categories,
            attributes.ibu::Nullable(String)            AS ibu,
            attributes.food_pairing::Nullable(String)   AS food_pairing,
            attributes.tasting_notes::Nullable(String)  AS tasting_notes,
            attributes.whisky_category::Nullable(String) AS whisky_category,    
            source_file
        FROM beverages_indexed
    )
);        

ALTER TABLE default.bev_flat ADD INDEX idx_name (name) TYPE text(tokenizer = splitByNonAlpha);
ALTER TABLE default.bev_flat MATERIALIZE INDEX idx_name SETTINGS mutations_sync = 1;




# 3. ПОИСК И СРАВНЕНИЕ ОДИНАКОВЫХ ЗНАЧЕНИЙ

## 3.1. импорт нескольких табиц с избранным столбцами из postgresql в replica
SET allow_experimental_database_materialized_postgresql = 1;
CREATE DATABASE drink_replica
ENGINE = MaterializedPostgreSQL(
        'wine_host:5432',
        'wine_db',
        'wine',
        'wine1'
)
SETTINGS
    materialized_postgresql_tables_list = 'drinks(id, title, subtitle, display_name, lwin, subcategory_id, site_id, producer_id, classification_id, designation_id, parcel_id), subcategories(id, category_id, name), producers(id, name, producertitle_id), categories(id, name), classifications(id, name), designations(id, name), parcels(id, name), producertitles(id, name), sites(id, name, subregion_id), subregions(id, name, region_id), regions(id, name, country_id), countries(id, name), varietals(id, name), drink_varietal_associations(id, drink_id, varietal_id, percentage), foods(id, name), drink_food_associations(id, drink_id, food_id)';

## 3.2. создание normalize table with indexes

### drinks_norm
CREATE TABLE default.drinks_norm
(
    id UInt64,  -- или Int64, в зависимости от типа исходного поля
    subcategory_id UInt64,
    lwin String,  -- предполагаемый тип
    norm_name String,  -- 👈 явно указываем как String, не Nullable
    title String       -- 👈 явно указываем как String, не Nullable
)
ENGINE = MergeTree
ORDER BY (id, norm_name, title)
AS 
SELECT 
    id,
    subcategory_id,
    lwin,
    normalize_text(coalesce(display_name, concat(title, ' ', subtitle))) as norm_name,
    normalize_text(concat(title, ' ', subtitle)) as title
FROM drink_replica.drinks
WHERE title IS NOT NULL AND norm_name IS NOT NULL;

ALTER TABLE drinks_norm ADD INDEX idx_norm_name_ngram norm_name TYPE ngrambf_v1(4096, 3, 2, 0) GRANULARITY 1;
ALTER TABLE drinks_norm MATERIALIZE INDEX idx_norm_name_ngram;
ALTER TABLE drinks_norm ADD INDEX idx_title_ngram title TYPE ngrambf_v1(4096, 3, 2, 0) GRANULARITY 1;
ALTER TABLE drinks_norm MATERIALIZE INDEX idx_title_ngram;

### PRODUCER
#### producers_norm
CREATE TABLE default.producers_norm
(
    id UInt64, 
    norm_name String,
    producertitle_id Nullable(UInt32)
)
ENGINE = MergeTree
ORDER BY (id, norm_name)
AS 
SELECT 
    id,
    normalize_text(name) as norm_name,
    producertitle_id
FROM drink_replica.producers
WHERE norm_name IS NOT NULL;

ALTER TABLE producers_norm ADD INDEX idx_producers_norm_token norm_name TYPE tokenbf_v1(512, 3, 0) GRANULARITY 1;
ALTER TABLE producers_norm MATERIALIZE INDEX idx_producers_norm_token;

#### brands_norm 
CREATE TABLE default.brands_norm
(
    name String, 
    norm_name String,
    producertitle_id Nullable(UInt32)
)
ENGINE = MergeTree
ORDER BY (id, norm_name)
AS 

WITH 
    prefixes AS (
        SELECT id, name, normalize_text(name) AS search_term, length(search_term) AS len
        FROM drink_replica.producertitles
    ),
    brands AS (
        SELECT normalize_text(brand) AS norm_brand, brand, COUNT() AS nmbr
        FROM beverages_indexed
        GROUP BY brand
    )
SELECT 
    brand, 
    if(is_match, trimLeft(substring(norm_brand, len + 1)), norm_brand) AS brand_cut,
    -- p_name,
    -- norm_brand,
    -- nmbr, 
    -- Если совпадение найдено (флаг = 1), берем ID, иначе 0
    if(is_match, p_id, null) AS producertitle_id
    -- if(is_match, p_name, '') AS p_name
FROM (
    SELECT 
        b.brand,
        b.norm_brand,
        b.nmbr, 
        p.id AS p_id, 
        p.name AS p_name, p.search_term as term,
        startsWith(b.norm_brand, concat(p.search_term, ' ')) AS is_match,
        p.len
    FROM brands AS b
    CROSS JOIN prefixes AS p
    ORDER BY b.brand ASC, is_match DESC, p.len DESC
)
-- WHERE is_match = 1
LIMIT 1 BY brand;

ALTER TABLE brands_norm ADD INDEX idx_brands_norm_token norm_name TYPE tokenbf_v1(512, 3, 0) GRANULARITY 1;
ALTER TABLE brands_norm MATERIALIZE INDEX idx_brands_norm_token;

#### поиск совпадений producers - brands
_WITH 
    -- 1. Разворачиваем бренды в плоский список: слово -> исходная строка
    brand_words AS (
        SELECT DISTINCT
            arrayJoin(tokens(norm_name)) AS word,
            name,
            norm_name
        FROM brands_norm
    ),
    -- 2. Разворачиваем производителей в плоский список: слово -> исходная строка
    prod_words AS (
        SELECT DISTINCT
            arrayJoin(tokens(norm_name)) AS word,
            norm_name AS producer_norm
        FROM producers_norm
    )
-- 3. Соединяем по строгому равенству СЛОВА (ClickHouse сделает это мгновенно)
SELECT 
    bw.name, 
    bw.norm_name, 
    pw.producer_norm,
    ngramDistance(pw.producer_norm, bw.norm_name) AS distance
FROM brand_words AS bw
INNER JOIN prod_words AS pw ON bw.word = pw.word
WHERE distance < 0.4
ORDER BY bw.norm_name ASC, length(pw.producer_norm) DESC, distance ASC
LIMIT 1 BY bw.norm_name_



## 3.3. поиск совпадений MAIN <> LWIN
### 3.3.1 создание таблицы drinks_lwins
CREATE TABLE default.drinks_lwins
(
    id UInt64, 
    id_old UInt64,
    dict Float32
)
ENGINE = MergeTree
ORDER BY (id, id_old)
AS
SELECT 
    m1.id,
    m2.id,
    -- m2.lwin,
    -- m1.title,
    -- m2.norm_name,
    ngramDistance(lower(m1.title), m2.norm_name) AS dist
FROM (SELECT * FROM drinks_norm WHERE lwin = '') AS m1
INNER JOIN (SELECT * FROM drinks_norm WHERE lwin != '') AS m2 
ON m1.subcategory_id = m2.subcategory_id
WHERE dist < 0.51 
AND hasAny(ngrams(m1.title, 3), ngrams(m2.norm_name, 3))
ORDER BY dist ASC, m1.id
LIMIT 1 BY m1.id;




## brands - producers
SELECT 
    d.id,
    d.norm_name,
    l.norm_brand,
    ngramDistance(lower(d.norm_name), l.norm_brand) AS dist
FROM producers_norm AS d
INNER JOIN brands AS l ON 1=1
WHERE dist < 0.4 
  AND hasAny(ngrams(d.norm_name, 3), ngrams(l.norm_brand, 3))
ORDER BY d.id, dist ASC
LIMIT 1 BY d.id;


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
