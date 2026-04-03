### USEFUL TIPS
1. импорт csv файла в таблицу:
   1. скопировать файл в /mnt/hdd_data/volumes/clickhouse/ch_data/user_files
CREATE TABLE beer_reviews 
ENGINE = MergeTree() 
ORDER BY tuple() 
AS SELECT * FROM file('beer_reviews.csv', 'CSVWithNames');
