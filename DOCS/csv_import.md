# import from csv file
1. ## скопировать csv файлы в /mnt/hdd_data/@named_volumes/clickhouse/ch_data/user_files
2. ## docker exec -it clickhouse_search clickhouse-client
beer
CREATE TABLE beer_raw ENGINE = MergeTree ORDER BY tuple() AS 
SELECT * FROM file('beer.csv', 'CSVWithNames')
SETTINGS format_csv_delimiter = ';';
scotch
CREATE TABLE scotch_raw ENGINE = MergeTree ORDER BY tuple() AS 
SELECT * FROM file('scotch.csv', 'CSVWithNames')
SETTINGS format_csv_delimiter = ';';
spirits
CREATE TABLE spirits_raw ENGINE = MergeTree ORDER BY tuple() AS 
SELECT * FROM file('spirits.csv', 'CSVWithNames')
SETTINGS format_csv_delimiter = ';';
wine1
CREATE TABLE wine1_raw ENGINE = MergeTree ORDER BY tuple() AS 
SELECT * FROM file('wine1.csv', 'CSVWithNames')
SETTINGS format_csv_delimiter = ';';
wine2
CREATE TABLE wine2_raw ENGINE = MergeTree ORDER BY tuple() AS 
SELECT * FROM file('wine2.csv', 'CSVWithNames')
SETTINGS format_csv_delimiter = ';';
wine3
CREATE TABLE wine3_raw ENGINE = MergeTree ORDER BY tuple() AS 
SELECT * FROM file('wine3.csv', 'CSVWithNames')
SETTINGS format_csv_delimiter = ';';
wine4
CREATE TABLE wine4_raw ENGINE = MergeTree ORDER BY tuple() AS 
SELECT * FROM file('wine4.csv', 'CSVWithNames')
SETTINGS format_csv_delimiter = ';';

3. # нормализация 
   1. ## winery:

WITH w1 AS (
    SELECT winery,
        nullIf(splitByChar(',', replaceRegexpAll(coalesce(appellation, ''), ', ', ','))[-1],
                '') AS country
        FROM default.wine4_raw
), w2 AS (
    SELECT winery, country, COUNT() as nmbr 
    FROM w1
    GROUP BY winery, country
), w3 AS (
    SELECT winery
    FROM w2
    GROUP BY winery
    HAVING COUNT() > 1
)
SELECT * FROM w2
JOIN w3 ON w2.winery = w3.winery
ORDER BY winery

## split appellation to county/region/subregion/region/site


WITH
    -- 1. Очищаем пробелы
    replaceRegexpAll(coalesce(appellation, ''), ', ', ',') AS clean_str,
    -- 2. Разбиваем в массив
    splitByChar(',', clean_str) AS arr,
    -- 3. Переворачиваем массив
    arrayReverse(arr) AS reversed_arr,
    -- 4. Расширяем до 4 элементов пустой строкой
    arrayResize(reversed_arr, 4, '') AS fixed_arr,
    -- 5. Переворачиваем обратно
    arrayReverse(fixed_arr) AS final_arr
SELECT
    -- 6. Безопасно преобразуем пустые строки в NULL с помощью nullIf
    nullIf(final_arr[1], '') AS site,
    nullIf(final_arr[2], '') AS subregion,
    nullIf(final_arr[3], '') AS region,
    nullIf(final_arr[4], '') AS country,
    appellation
FROM default.wine4_raw;












SELECT winery, count()
FROM (
    SELECT winery, country 
    FROM (
        SELECT winery,
        nullIf(splitByChar(',', replaceRegexpAll(coalesce(appellation, ''), ', ', ','))[-1],
                '') AS country
        FROM default.wine4_raw)
    GROUP BY winery, country
    ORDER BY winery
) GROUP BY winery
HAVING count() >1



SELECT
arrayReverse(splitByChar(',', replaceRegexpAll(coalesce(appellation, ''), ', ', ',')))
FROM default.wine4_raw;