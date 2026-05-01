## раздел настроек nginx для прямой раздачи - подумать и проверить.

# 1. Сначала добавляем новый upstream для SeaweedFS
upstream seaweed_backend {
    server seaweedfs_volume:8080;
    keepalive 32;
}

# 2. Обновляем location для изображений (замена mongodb на seaweedfs)
location ~ ^/mongodb/(thumbnails|images)/(.*)$ {
    set $seaweed_fid $2;
    set $target_backend "";

    # Пытаемся получить файл из SeaweedFS
    proxy_pass http://seaweed_backend/$seaweed_fid;
    
    # НАСТРОЙКИ для 100% совместимости с MongoDB GridFS API
    proxy_http_version 1.1;
    proxy_set_header Connection "";
    proxy_set_header Host $host;
    
    # --- КЭШИРОВАНИЕ (ОСТАЕТСЯ БЕЗ ИЗМЕНЕНИЙ) ---
    proxy_cache STATIC;
    proxy_cache_valid 200 24h;
    proxy_cache_use_stale error timeout;
    proxy_cache_key "$host$request_uri$http_authorization";
    
    add_header Cache-Control "public, max-age=31536000, immutable";
    
    proxy_hide_header Set-Cookie;
    proxy_ignore_headers Set-Cookie;
    
    # --- ОБРАБОТКА ОШИБОК (Graceful Fallback) ---
    # Если SeaweedFS вернул 404 (файл не найден) или сервер недоступен,
    # Nginx автоматически перенаправит запрос в старый FastAPI (MongoDB)
    proxy_intercept_errors on;
    error_page 404 502 503 = @mongodb_fallback;
    
    # Таймауты для SeaweedFS
    proxy_connect_timeout 2s;
    proxy_read_timeout 5s;
}

# --- FALLBACK БЛОК: старый способ через ваш FastAPI (для переноса старых файлов)---
location @mongodb_fallback {
    set $upstream_app prod-app-1;
    proxy_pass http://$upstream_app:8091$request_uri;
    
    # Копируем все настройки из вашего оригинального location
    proxy_cache STATIC;
    proxy_cache_valid 200 24h;
    proxy_cache_use_stale error timeout;
    proxy_cache_key "$host$request_uri$http_authorization";
    
    add_header Cache-Control "public, max-age=31536000, immutable";
    proxy_set_header Host $host;
    proxy_set_header Authorization $http_authorization;
    proxy_pass_header Authorization;
    proxy_hide_header Set-Cookie;
    proxy_ignore_headers Set-Cookie;
}