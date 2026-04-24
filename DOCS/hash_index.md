# создание и заполнение таблицы с hash indexes
1. # вход в контейнер
    docker exec -it clickhouse_search clickhouse-client
2. # создание таблицы
CREATE TABLE default.beverages_indexed
(`id` UUID DEFAULT generateUUIDv4(),
 `name` String, 
 `description` String,
 `category` LowCardinality(String), 
 `country` Nullable(String),
 `brand` Nullable(String), 
 `abv` Nullable(Float32),
 `price` Nullable(Decimal(10,2)),  
 `rating` Nullable(Float32), 
 `attributes` JSON,
 `file_hash` String,
 `source_file` String,
 `created_at` DateTime DEFAULT now(),
 `word_hashes` Array(Int64),
 INDEX idx_word_hashes word_hashes TYPE bloom_filter(0.01) GRANULARITY 1
 )
 ENGINE = MergeTree
 ORDER BY id;

3. # перенос данных с генерацией хэшей
INSERT INTO default.beverages_indexed
SELECT
    id, name, description, category, country, brand, abv, price, rating, attributes, file_hash, source_file, created_at,
    -- ГЕНЕРАЦИЯ ХЕШЕЙ
    arrayMap(t -> reinterpretAsInt64(farmFingerprint64(t)), 
        arrayFilter(t -> (
            length(t) > 1 
            AND (
                NOT match(t, '^[0-9#]+$') 
                OR (
                    toInt64OrZero(splitByChar('#', t)[1]) >= 1 
                    AND toInt64OrZero(splitByChar('#', t)[1]) <= 2050
                )
            )
        ),
        arrayMap(t -> trim(BOTH '#' FROM t), 
            splitByChar(' ', 
                -- 3. Заменяем всё лишнее на пробел (теперь это безопасно)
                replaceRegexpAll(
                    -- 2. Собираем символы обратно в строку
                    arrayStringConcat(
                        -- 1. Посимвольная замена UTF-8 (аналог _TRANS_MAP)
                        arrayMap(s -> transform(s, 
                            ['ü','ö','ä','é','è','ê','ë','à','â','î','ï','ô','û','ù','ç','ñ','á','í','ó','ú','ã','õ','å','ø','æ','ł','ń','ś','ź','ż','č','š','ž','.',','], 
                            ['u','o','a','e','e','e','e','a','a','i','i','o','u','u','c','n','a','i','o','u','a','o','a','o','ae','l','n','s','z','z','c','s','z','#','#'], 
                            s), 
                            -- Разбиваем строку на массив символов UTF-8
                            splitByRegexp('', replace(lower(concat(name, ' ', coalesce(brand, ''), ' ', category, ' ', coalesce(country, ''))), 'ß', 'ss'))
                        )
                    ),
                    '[^a-z0-9а-яё#]', ' '
                )
            )
        )
    )) as word_hashes
FROM default.beverages_rag;

4. # создание таблицы слов
CREATE TABLE default.beverages_words
(
    `word` String,
    `hash` Int64,
    `freq` UInt64
)
ENGINE = SummingMergeTree(freq)
ORDER BY (word, hash);


5. # заполнение таблицы слов

INSERT INTO default.beverages_words
SELECT 
    token as word,
    reinterpretAsInt64(farmHash64(token)) as hash,
    count() as freq
FROM (
    -- Повторяем логику токенизации, чтобы сопоставить слово с хешем
    SELECT DISTINCT
        id,
        arrayJoin(
            arrayFilter(t -> (
                length(t) > 1 
                AND (NOT match(t, '^[0-9#]+$') OR (toInt64OrZero(splitByChar('#', t)[1]) >= 1 AND toInt64OrZero(splitByChar('#', t)[1]) <= 2050))
            ),
            arrayMap(t -> trim(BOTH '#' FROM t), 
                splitByChar(' ', 
                    replaceRegexpAll(
                        arrayStringConcat(
                            arrayMap(s -> transform(s, 
                                ['ü','ö','ä','é','è','ê','ë','à','â','î','ï','ô','û','ù','ç','ñ','á','í','ó','ú','ã','õ','å','ø','æ','ł','ń','ś','ź','ż','č','š','ž','.',','], 
                                ['u','o','a','e','e','e','e','a','a','i','i','o','u','u','c','n','a','i','o','u','a','o','a','o','ae','l','n','s','z','z','c','s','z','#','#'], 
                                s), 
                                splitByRegexp('', replace(lower(concat(name, ' ', coalesce(brand, ''), ' ', category, ' ', coalesce(country, ''))), 'ß', 'ss'))
                            )
                        ),
                        '[^a-z0-9а-яё#]', ' '
                    )
                )
            ))
        ) as token
    FROM default.beverages_indexed
)
GROUP BY word, hash;


