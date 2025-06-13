# Настройка доступа к Yandex Object Storage (S3) через Keycloak SSO с использованием oauth2-proxy и Nginx

## Архитектура решения

```
Пользователь -> Nginx -> oauth2-proxy -> Keycloak (аутентификация)
       |
       v
Yandex Object Storage (S3)
```

## Необходимые компоненты

Для реализации решения вам понадобятся три ключевых компонента:
Keycloak (сервер SSO), oauth2-proxy (прокси для аутентификации OAuth2) и Nginx (обратный прокси и балансировщик нагрузки), обеспечивающие безопасный доступ к Yandex Object Storage.

## Шаг 1: Настройка Keycloak

Создайте новый клиент в Keycloak:
- Client ID: `s3-proxy`
- Client Protocol: `openid-connect`
- Access Type: `confidential`
- Valid Redirect URIs: `https://s3.yourdomain.com/oauth2/callback`
- Web Origins: `https://s3.yourdomain.com`

Создайте роли для пользователей:
- `s3-admin` - полный доступ (storage.editor).

Назначьте эти роли пользователям или группам в соответствии с необходимыми правами доступа.

## Шаг 2: Настройка oauth2-proxy

Используйте базу из [helm чарта oauth2-proxy](https://github.com/oauth2-proxy/manifests/tree/main/helm/oauth2-proxy) для настройки. Конфигурационный файл `oauth2-proxy.cfg` должен выглядеть следующим образом:

```ini
## Общие настройки
http_address = "0.0.0.0:4180"
upstreams = [
    "http://localhost:4181"
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

Конфигурация Nginx `nginx.conf` будет следующей:

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

        if ($http_x_auth_request_user !~* "s3-admin") {
            return 403;
        }

        proxy_pass http://localhost:4181;
    }
}
```

## Шаг 4: Настройка политик доступа в Yandex Object Storage

Создайте сервисный аккаунт в Yandex Cloud и назначьте ему роль `storage.editor` для полного доступа. Создайте статические ключи доступа для этого аккаунта и настройте политик доступа при необходимости.

## Шаг 5: Запуск системы

Запустите oauth2-proxy следующим образом:
```bash
oauth2-proxy --config=./oauth2-proxy.cfg
```

Запустите Nginx:
```bash
nginx -c /path/to/your/nginx.conf
```

## Заключение

Данная конфигурация позволяет аутентифицировать пользователей через Keycloak и проверять их роли, обеспечивая доступ к Yandex Object Storage на основе предоставленных прав. Рекомендуется проводить тестирование и обеспечить соблюдение правил безопасности в вашем окружении.
