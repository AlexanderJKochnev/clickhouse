#  после созадения таблицы pg_drink

## создание индекса
-- 1. Пересоздаем функцию (с исправленным аргументом s на конце)
CREATE OR REPLACE FUNCTION default.normalize_text AS (s) ->
    replaceRegexpAll(
        lower(
            replaceRegexpAll(replaceRegexpAll(replaceRegexpAll(replaceRegexpAll(replaceRegexpAll(replaceRegexpAll(replaceRegexpAll(replaceRegexpAll(replaceRegexpAll(replaceRegexpAll(replaceRegexpAll(replaceRegexpAll(replaceRegexpAll(replaceRegexpAll(replaceRegexpAll(replaceRegexpAll(replaceRegexpAll(replaceRegexpAll(replaceRegexpAll(replaceRegexpAll(replaceRegexpAll(replaceRegexpAll(
                replaceRegexpAll(coalesce(s, ''), '-', ' '),
            'ü', 'u'), 'ö', 'o'), 'ä', 'a'), 'ß', 'ss'), '[éèêë]', 'e'), '[àâãå]', 'a'), '[îï]', 'i'), '[ôõø]', 'o'), '[ûù]', 'u'), 'ç', 'c'), 'ñ', 'n'), '[á]', 'a'), '[í]', 'i'), '[ó]', 'o'), '[ú]', 'u'), 'æ', 'ae'), 'ł', 'l'), 'ń', 'n'), 'ś', 's'), 'ź', 'z'), 'ż', 'z'), '[^a-zA-Z0-9 ]', '')
        ),
    ' {2,}', ' ');

-- 2. Добавляем индекс нового типа text с препроцессором (валидно для 26.4)
ALTER TABLE default.pg_drink 
ADD INDEX idx_norm_text wine TYPE text(
    tokenizer = splitByNonAlpha,
    preprocessor = normalize_text(wine)
) GRANULARITY 1;

-- 3. Запускаем индексацию существующих 517k строк
ALTER TABLE default.pg_drink MATERIALIZE INDEX idx_norm_text;


## Выявление дубликатов в pg_drink
DROP TABLE IF EXISTS default.tmp_drink_duplicates;

CREATE TABLE default.tmp_drink_duplicates ENGINE = MergeTree() ORDER BY wine_norm AS
SELECT 
    -- assumeNotNull убирает Nullable-обертку, позволяя использовать поле в ORDER BY
    assumeNotNull(normalize_text(wine)) AS wine_norm,
    winery_id,
    groupArray(id) AS all_ids,
    min(id) AS keep_id,
    arraySlice(groupArray(id), 2) AS delete_ids,
    count() AS duplicate_count
FROM default.pg_drink
WHERE wine IS NOT NULL AND wine != '' AND winery_id IS NOT NULL
GROUP BY wine_norm, winery_id
HAVING duplicate_count > 1;


## Слияние и дедупликация (Безопасный перенос связей)
### Создаем легкую Join-таблицу для мгновенного маппинга "Удаляемый ID -> Главный ID"
CREATE TABLE default.join_drink_mapping (delete_id UInt32, keep_id UInt32) ENGINE = Join(ANY, LEFT, delete_id);

INSERT INTO default.join_drink_mapping 
SELECT arrayJoin(delete_ids) AS delete_id, keep_id FROM default.tmp_drink_duplicates;

### Обновляем таблицы связей Many-to-Many
#### Перепривязка сортов винограда (pg_drink_varietal)
-- Создаем чистую копию с подмененными ID, схлопывая возможные дубликаты через DISTINCT
CREATE TABLE default.tmp_varietal_clean ENGINE = MergeTree() ORDER BY (drink_id, varietal_id) AS
SELECT DISTINCT
    -- Если drink_id есть в списке удаляемых, берем его мастер-ID, иначе оставляем как есть
    if(joinGet('default.join_drink_mapping', 'keep_id', drink_id) > 0, 
       joinGet('default.join_drink_mapping', 'keep_id', drink_id), 
       drink_id) AS drink_id,
    varietal_id
FROM default.pg_drink_varietal;

-- Подменяем боевую таблицу временной
EXCHANGE TABLES default.pg_drink_varietal AND default.tmp_varietal_clean;

-- Удаляем старые данные
DROP TABLE default.tmp_varietal_clean;

#### Перепривязка еды (pg_drink_food)
CREATE TABLE default.tmp_food_clean ENGINE = MergeTree() ORDER BY (drink_id, food_id) AS
SELECT DISTINCT
    if(joinGet('default.join_drink_mapping', 'keep_id', drink_id) > 0, 
       joinGet('default.join_drink_mapping', 'keep_id', drink_id), 
       drink_id) AS drink_id,
    food_id
FROM default.pg_drink_food;

EXCHANGE TABLES default.pg_drink_food AND default.tmp_food_clean;
DROP TABLE default.tmp_food_clean;

#### Перепривязка ингредиентов (pg_drink_ingredient)
CREATE TABLE default.tmp_ingredient_clean ENGINE = MergeTree() ORDER BY (drink_id, ingredient_id) AS
SELECT DISTINCT
    if(joinGet('default.join_drink_mapping', 'keep_id', drink_id) > 0, 
       joinGet('default.join_drink_mapping', 'keep_id', drink_id), 
       drink_id) AS drink_id,
    ingredient_id
FROM default.pg_drink_ingredient;

EXCHANGE TABLES default.pg_drink_ingredient AND default.tmp_ingredient_clean;
DROP TABLE default.tmp_ingredient_clean;

#### Перепривязка вкусовых заметок (pg_drink_tasting_note)
CREATE TABLE default.tmp_tasting_clean ENGINE = MergeTree() ORDER BY (drink_id, tasting_note_id) AS
SELECT DISTINCT
    if(joinGet('default.join_drink_mapping', 'keep_id', drink_id) > 0, 
       joinGet('default.join_drink_mapping', 'keep_id', drink_id), 
       drink_id) AS drink_id,
    tasting_note_id
FROM default.pg_drink_tasting_note;

EXCHANGE TABLES default.pg_drink_tasting_note AND default.tmp_tasting_clean;
DROP TABLE default.tmp_tasting_clean;




### Склеиваем обзоры (Review) на главном ID, чтобы не потерять информацию из разных файлов:
CREATE TABLE default.join_merged_reviews (id UInt32, merged_review String) ENGINE = Join(ANY, LEFT, id);

INSERT INTO default.join_merged_reviews
SELECT 
    b.keep_id,
    arrayStringConcat(groupUniqArray(coalesce(a.review, '')), ' | ') AS merged_review
FROM default.pg_drink AS a
INNER JOIN default.tmp_drink_duplicates AS b ON a.winery_id = b.winery_id AND normalize_text(a.wine) = b.wine_norm
GROUP BY b.keep_id;

-- Прописываем объединенные обзоры в мастер-строки
ALTER TABLE default.pg_drink 
UPDATE review = joinGet('default.join_merged_reviews', 'merged_review', id)
WHERE id IN (SELECT keep_id FROM default.tmp_drink_duplicates);


### Физическое удаление дубликатов из pg_drink
ALTER TABLE default.pg_drink 
DELETE WHERE id IN (SELECT arrayJoin(delete_ids) FROM default.tmp_drink_duplicates);

## отслеживание мутаций 
SELECT command, is_done FROM system.mutations