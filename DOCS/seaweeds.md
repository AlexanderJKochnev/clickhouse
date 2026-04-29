Подход 2: Использовать встроенный weed backup (рекомендуемый для инкрементов)
SeaweedFS имеет родной механизм инкрементального бэкапа, который работает поверх вашей файловой системы .

bash
# Ручной бэкап одного тома
weed backup -server=localhost:9333 -dir=/path/to/backup/dir -volumeId=5

# Цикл для бэкапа всех существующих томов (script)
for vol_id in {1..100}; do
    weed backup -server=localhost:9333 -dir="${BACKUP_DIR}" -volumeId=${vol_id}
done