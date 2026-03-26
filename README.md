# clickhouse
clickhouse_repo


1. ALTER USER wine_user WITH REPLICATION;  #  выполнить в postgresql если пользователь не имеет прав на реплики
2. docker exec -it clickhouse_search clickhouse-client  # войти в clickhouse
3. проверка наличия таблиц 
    SHOW DATABASES; -- Должна появиться wine_replica
    USE wine_replica;
    SHOW TABLES;    -- Должна появиться таблица items
