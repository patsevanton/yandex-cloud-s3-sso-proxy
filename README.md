# Настройка доступа к Yandex Object Storage (S3) через Keycloak SSO с использованием oauth2-proxy и Nginx

## Архитектура решения

```
Пользователь -> Nginx -> oauth2-proxy -> Keycloak (аутентификация)
       |
       v
Yandex Object Storage (S3)
```

## Необходимые компоненты

1. Keycloak - сервер SSO
2. oauth2-proxy - прокси для аутентификации OAuth2
3. Nginx - обратный прокси и балансировщик нагрузки

## Шаг 1: Настройка Keycloak

1. Создайте новый клиент в Keycloak:
   - Client ID: `s3-proxy`
   - Client Protocol: `openid-connect`
   - Access Type: `confidential`
   - Valid Redirect URIs: `https://s3.yourdomain.com/oauth2/callback`
   - Web Origins: `https://s3.yourdomain.com`

2. Создайте роли для разных уровней доступа:
   - `s3-reader` - только чтение
   - `s3-writer` - чтение и запись
   - `s3-admin` - полный доступ

3. Назначьте роли пользователям или группам

## Шаг 2: Настройка oauth2-proxy

Конфигурационный файл `oauth2-proxy.cfg`:

```ini
## Общие настройки
http_address = "0.0.0.0:4180"
upstreams = [
    "http://localhost:4181" # Nginx будет слушать на этом порту для S3
]

## Настройки провайдера OIDC
provider = "oidc"
oidc_issuer_url = "https://keycloak.yourdomain.com/auth/realms/your-realm"
client_id = "s3-proxy"
client_secret = "your-client-secret-from-keycloak"
cookie_secret = "generated-secure-random-string"

## Настройки сессии
cookie_secure = true
cookie_httponly = true
cookie_refresh = "1h"
cookie_expire = "8h"

## Проверка ролей
skip_auth_regex = ["^/healthz$"]
email_domains = ["*"]
whitelist_domains = [".yourdomain.com"]

## Настройки для интеграции с S3
ssl_insecure_skip_verify = false
pass_access_token = true
pass_authorization_header = true
set_authorization_header = true
set_xauthrequest = true
```

## Шаг 3: Настройка Nginx

Конфигурация Nginx `nginx.conf`:

```nginx
upstream s3_backend {
    server s3.storage.yandexcloud.net:443;
}

server {
    listen 4181 ssl;
    server_name s3.yourdomain.com;

    ssl_certificate /path/to/your/cert.pem;
    ssl_certificate_key /path/to/your/key.pem;

    # Проксирование в Yandex S3
    location / {
        proxy_pass https://s3_backend;
        
        # Передаем заголовки аутентификации
        proxy_set_header Authorization $http_authorization;
        proxy_pass_header Authorization;
        
        # Дополнительные заголовки для S3
        proxy_set_header Host s3.storage.yandexcloud.net;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        
        # Обработка ошибок
        proxy_intercept_errors on;
        error_page 403 = @error403;
    }

    location @error403 {
        return 302 /oauth2/sign_in?rd=$request_uri;
    }
}

server {
    listen 443 ssl;
    server_name s3.yourdomain.com;

    ssl_certificate /path/to/your/cert.pem;
    ssl_certificate_key /path/to/your/key.pem;

    # Проксирование в oauth2-proxy
    location /oauth2/ {
        proxy_pass http://oauth2-proxy:4180;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Scheme $scheme;
        proxy_set_header X-Auth-Request-Redirect $request_uri;
    }

    # Проверка аутентификации перед доступом к S3
    location / {
        auth_request /oauth2/auth;
        error_page 401 = /oauth2/sign_in;

        # Передача информации об аутентификации
        auth_request_set $user $upstream_http_x_auth_request_user;
        auth_request_set $token $upstream_http_x_auth_request_access_token;
        auth_request_set $auth_cookie $upstream_http_set_cookie;
        
        proxy_set_header X-User $user;
        proxy_set_header X-Access-Token $token;
        proxy_set_header Authorization "Bearer $token";
        
        add_header Set-Cookie $auth_cookie;

        # Проверка ролей
        if ($http_x_auth_request_user !~* "s3-reader|s3-writer|s3-admin") {
            return 403;
        }

        proxy_pass http://localhost:4181;
    }
}
```

## Шаг 4: Настройка политик доступа в Yandex Object Storage

1. Создайте сервисный аккаунт в Yandex Cloud
2. Назначьте роли сервисному аккаунту:
   - `storage.editor` - для полного доступа
   - `storage.viewer` - для доступа только на чтение

3. Создайте статические ключи доступа для сервисного аккаунта

4. Настройте бакетные политики (если нужно разграничение на уровне бакетов)

## Шаг 5: Запуск системы

1. Запустите oauth2-proxy:
```bash
oauth2-proxy --config=./oauth2-proxy.cfg
```

2. Запустите Nginx:
```bash
nginx -c /path/to/your/nginx.conf
```

## Дополнительные настройки

### Динамическое ограничение доступа на основе ролей

Модифицируйте конфигурацию Nginx для проверки ролей:

```nginx
location / {
    auth_request /oauth2/auth;
    error_page 401 = /oauth2/sign_in;

    # Проверка ролей для разных типов запросов
    if ($request_method = PUT) {
        set $role_check "s3-writer s3-admin";
    }
    if ($request_method = POST) {
        set $role_check "s3-writer s3-admin";
    }
    if ($request_method = DELETE) {
        set $role_check "s3-admin";
    }

    # Проверка наличия нужной роли
    if ($http_x_auth_request_user !~* $role_check) {
        return 403;
    }

    proxy_pass http://localhost:4181;
}
```

### Логирование

Добавьте в конфигурацию oauth2-proxy:
```ini
logging_filename = "/var/log/oauth2-proxy/oauth2-proxy.log"
logging_max_size = 10
logging_max_age = 7
logging_max_backups = 3
request_logging = true
```

## Заключение

Эта конфигурация позволяет:
1. Аутентифицировать пользователей через Keycloak
2. Проверять их роли перед доступом к S3
3. Ограничивать операции (чтение/запись) на основе ролей
4. Логировать все запросы

Для production окружения рекомендуется:
- Настроить мониторинг
- Добавить балансировщик нагрузки
- Реализовать автоматическое масштабирование
- Настроить резервное копирование конфигураций
