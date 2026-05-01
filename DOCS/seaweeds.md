# SEAWEEDFS
1. ## проверка соединения fastapi и seaweed (из контейнера fastapi)
docker compose exec -it app sh (из директории)
python -c "import urllib.request; print(urllib.request.urlopen('http://seaweedfs_master:9333/cluster/status').read())"
python -c "import urllib.request; print(urllib.request.urlopen('http://seaweedfs_master:9333/dir/assign').read())"
python -c "import urllib.request; print(urllib.request.urlopen('http://seaweedfs_master:9333/dir/status').read())"
b'{"Topology":{"Max":500,"Free":500,"DataCenters":[{"Id":"dc1","Racks":[{"Id":"rack1","DataNodes":[{"Url":"seaweedfs_volume:8080","PublicUrl":"https://abc8888.ru","Volumes":0,"EcShards":0,"Max":500,"VolumeIds":" "}]}]}],"Layouts":[{"replication":"001","ttl":"","writables":null,"collection":"","diskType":"hdd"}]},"TopologyId":"21342b0c-c6f7-47f5-ab3f-5876dd1e8ec7","Version":"30GB 4.22 0b3cc8d12"}'
3. ## создание таблицы в clickhouse
4. ### Создаем таблицу метаданных ()
CREATE TABLE images_metadata
(
    `fid_thumb` String NOT NULL,          -- thumb
    `fid` String NOT NULL,                -- Полный FID
    `table` LowCardinality(String) NOT NULL,
    `size_bytes` UInt32 NOT NULL,
    `thumb_size_bytes` UInt32 NOT NULL,
    `mime_type` LowCardinality(String) NOT NULL,
    `tags` Array(String) NOT NULL,
    `inserted_at` DateTime64(3) DEFAULT now64(3),  -- по этому полю осуществляется версионирование также
    `is_deleted` UInt8 DEFAULT 0,                  -- пометка об удалении 1 удалено
)
ENGINE = ReplacingMergeTree(inserted_at)            -- позволяет выводить только последние версии 
PARTITION BY toYYYYMM(inserted_at)
-- Выносим fid в начало для моментального поиска "точечным" запросом
ORDER BY (fid, `table`)
SETTINGS index_granularity = 8192;
-- Индекс на теги оставляем, это правильно для Array
ALTER TABLE images_metadata ADD INDEX idx_tags tags TYPE bloom_filter(0.01) GRANULARITY 3;
-- ALTER TABLE images_metadata ADD INDEX idx_fid_thumb fid_thumb TYPE bloom_filter GRANULARITY 1;
-- Удалить физически через 30 дней после пометки is_deleted = 1
ALTER TABLE images_metadata MODIFY TTL inserted_at + INTERVAL 30 DAY WHERE is_deleted = 1;

CREATE VIEW images_metadata_active AS
SELECT * FROM images_metadata FINAL WHERE is_deleted = 0;








Подход 2: Использовать встроенный weed backup (рекомендуемый для инкрементов)
SeaweedFS имеет родной механизм инкрементального бэкапа, который работает поверх вашей файловой системы .

bash
# Ручной бэкап одного тома
weed backup -server=localhost:9333 -dir=/path/to/backup/dir -volumeId=5

# Цикл для бэкапа всех существующих томов (script)
for vol_id in {1..100}; do
    weed backup -server=localhost:9333 -dir="${BACKUP_DIR}" -volumeId=${vol_id}
done