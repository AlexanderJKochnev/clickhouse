# SEAWEEDFS
## 1. проверка соединения fastapi и seaweed (из контейнера fastapi)
docker compose exec -it app sh (из директории)
python -c "import urllib.request; print(urllib.request.urlopen('http://seaweedfs_master:9333/cluster/status').read())"
python -c "import urllib.request; print(urllib.request.urlopen('http://seaweedfs_master:9333/dir/assign').read())"
python -c "import urllib.request; print(urllib.request.urlopen('http://seaweedfs_master:9333/dir/status').read())"
b'{"Topology":{"Max":500,"Free":500,"DataCenters":[{"Id":"dc1","Racks":[{"Id":"rack1","DataNodes":[{"Url":"seaweedfs_volume:8080","PublicUrl":"https://abc8888.ru","Volumes":0,"EcShards":0,"Max":500,"VolumeIds":" "}]}]}],"Layouts":[{"replication":"001","ttl":"","writables":null,"collection":"","diskType":"hdd"}]},"TopologyId":"21342b0c-c6f7-47f5-ab3f-5876dd1e8ec7","Version":"30GB 4.22 0b3cc8d12"}'
## 2. создание таблицы в clickhouse
### 2.1. Создаем таблицу метаданных ()
CREATE TABLE default.images_metadata
(
    `fid_thumb` String,
    `fid` String,
    `table` LowCardinality(String),
    `size_bytes` UInt32,
    `thumb_size_bytes` UInt32,
    `mime_type` LowCardinality(String),
    `tags` String,
    `inserted_at` DateTime64(3) DEFAULT now64(3),
    `is_deleted` UInt8 DEFAULT 0,
    
    -- Оптимальный текстовый индекс для ClickHouse 26:
    -- 1. preprocessor = lower(tags) переводит весь текст в нижний регистр
    -- 2. tokenizer = splitByNonAlpha разбивает строку на слова и выкидывает мусор/пунктуацию
    INDEX idx_tags_text tags TYPE text(
        tokenizer = splitByNonAlpha,
        preprocessor = lower(tags)
    ) GRANULARITY 1
)
ENGINE = ReplacingMergeTree(inserted_at)
PARTITION BY toYYYYMM(inserted_at)
-- Быстрый поиск по идентификаторам seaweed
ORDER BY (fid, fid_thumb)
-- ОЧИСТКА ЧЕРЕЗ 10 ДНЕЙ ПОСЛЕ УДАЛЕНИЯ
TTL inserted_at + toIntervalDay(10) WHERE is_deleted = 1
SETTINGS index_granularity = 8192;

### 2.2. Создаем view default.images_metadata_active (скрывает удаленные записи)
CREATE VIEW images_metadata_active AS
SELECT * FROM images_metadata FINAL WHERE is_deleted = 0;

## 3. поисковые запросы по тэгам (произвольный текст - индекс очистит сам)
-- Поиск строк, содержащих тег "москва" (регистр и знаки препинания в запросе не важны)
SELECT * 
FROM default.images_metadata 
WHERE hasToken(tags, 'Москва!');

-- Поиск строк, содержащих сразу несколько тегов в любом порядке
SELECT * 
FROM default.images_metadata 
WHERE hasAllTokens(tags, 'вкусный кофе');
