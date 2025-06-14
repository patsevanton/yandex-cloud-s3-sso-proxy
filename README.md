# Настройка доступа к Yandex Object Storage (S3) через Keycloak с использованием oauth2-proxy и Nginx

## Введение

В современных облачных инфраструктурах безопасность доступа к объектным хранилищам является критически важной задачей. Yandex Object Storage, совместимый с S3 API, предоставляет надежное решение для хранения данных, но требует грамотной настройки системы аутентификации и авторизации. В этой статье мы рассмотрим, как организовать безопасный доступ к Yandex Object Storage через единую точку входа с использованием Keycloak в качестве провайдера идентификации, oauth2-proxy для проксирования OAuth2 запросов и Nginx в качестве веб-сервера.

## Архитектура решения

Предлагаемое решение основано на следующей архитектуре: пользователь обращается к Nginx, который перенаправляет запросы на oauth2-proxy. OAuth2-proxy проверяет аутентификацию через Keycloak и, в случае успеха, пропускает запросы к Yandex Object Storage. Все компоненты будут развернуты в Docker контейнерах с использованием docker-compose для упрощения управления и масштабирования.

## Подготовка окружения

Перед началом настройки убедитесь, что у вас установлены Docker и docker-compose. Также вам потребуется доступ к Yandex Cloud и созданный бакет в Object Storage.

Создайте директорию проекта и необходимую структуру файлов:

```bash
mkdir yandex-s3-keycloak-proxy
cd yandex-s3-keycloak-proxy
mkdir -p nginx/conf.d
mkdir -p keycloak/themes
```

## Настройка docker-compose.yml

Создайте файл `docker-compose.yml` со следующим содержимым:

```yaml
version: '3.8'

services:
  postgres:
    image: postgres:15
    environment:
      POSTGRES_DB: keycloak
      POSTGRES_USER: keycloak
      POSTGRES_PASSWORD: keycloak_password
    volumes:
      - postgres_data:/var/lib/postgresql/data
    networks:
      - keycloak-network

  keycloak:
    image: quay.io/keycloak/keycloak:22.0
    environment:
      KC_DB: postgres
      KC_DB_URL: jdbc:postgresql://postgres:5432/keycloak
      KC_DB_USERNAME: keycloak
      KC_DB_PASSWORD: keycloak_password
      KC_HOSTNAME: keycloak.yourdomain.com
      KC_HOSTNAME_STRICT: "false"
      KC_HOSTNAME_STRICT_HTTPS: "false"
      KC_HTTP_ENABLED: "true"
      KC_PROXY: edge
      KEYCLOAK_ADMIN: admin
      KEYCLOAK_ADMIN_PASSWORD: admin_password
    command: start-dev
    ports:
      - "8080:8080"
    depends_on:
      - postgres
    networks:
      - keycloak-network

  oauth2-proxy:
    image: quay.io/oauth2-proxy/oauth2-proxy:v7.5.0
    environment:
      OAUTH2_PROXY_PROVIDER: keycloak-oidc
      OAUTH2_PROXY_CLIENT_ID: yandex-s3-client
      OAUTH2_PROXY_CLIENT_SECRET: your-client-secret
      OAUTH2_PROXY_REDIRECT_URL: https://yourdomain.com/oauth2/callback
      OAUTH2_PROXY_OIDC_ISSUER_URL: http://keycloak:8080/realms/yandex-s3
      OAUTH2_PROXY_EMAIL_DOMAINS: "*"
      OAUTH2_PROXY_COOKIE_SECRET: your-cookie-secret-32-bytes-long!!!
      OAUTH2_PROXY_COOKIE_SECURE: "false"
      OAUTH2_PROXY_HTTP_ADDRESS: 0.0.0.0:4180
      OAUTH2_PROXY_UPSTREAMS: http://nginx:80
      OAUTH2_PROXY_PASS_ACCESS_TOKEN: "true"
      OAUTH2_PROXY_PASS_AUTHORIZATION_HEADER: "true"
      OAUTH2_PROXY_SET_AUTHORIZATION_HEADER: "true"
      OAUTH2_PROXY_SKIP_PROVIDER_BUTTON: "true"
    networks:
      - keycloak-network
    depends_on:
      - keycloak

  nginx:
    image: nginx:alpine
    volumes:
      - ./nginx/conf.d:/etc/nginx/conf.d
      - ./nginx/nginx.conf:/etc/nginx/nginx.conf
    ports:
      - "80:80"
      - "443:443"
    networks:
      - keycloak-network
    depends_on:
      - oauth2-proxy

volumes:
  postgres_data:

networks:
  keycloak-network:
    driver: bridge
```

## Настройка Nginx

Создайте файл `nginx/nginx.conf`:

```nginx
user nginx;
worker_processes auto;
error_log /var/log/nginx/error.log warn;
pid /var/run/nginx.pid;

events {
    worker_connections 1024;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    log_format main '$remote_addr - $remote_user [$time_local] "$request" '
                    '$status $body_bytes_sent "$http_referer" '
                    '"$http_user_agent" "$http_x_forwarded_for"';

    access_log /var/log/nginx/access.log main;

    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    types_hash_max_size 2048;

    include /etc/nginx/conf.d/*.conf;
}
```

Создайте файл `nginx/conf.d/default.conf`:

```nginx
upstream oauth2_proxy {
    server oauth2-proxy:4180;
}

server {
    listen 80;
    server_name yourdomain.com;
    
    # Перенаправление всех запросов на oauth2-proxy
    location /oauth2/ {
        proxy_pass http://oauth2_proxy;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Scheme $scheme;
        proxy_set_header X-Auth-Request-Redirect $request_uri;
    }

    # Основной location для проксирования к S3
    location / {
        auth_request /oauth2/auth;
        error_page 401 = /oauth2/sign_in;

        # Передача заголовков от oauth2-proxy
        auth_request_set $user   $upstream_http_x_auth_request_user;
        auth_request_set $email  $upstream_http_x_auth_request_email;
        auth_request_set $auth_header $upstream_http_authorization;

        proxy_set_header X-User  $user;
        proxy_set_header X-Email $email;
        proxy_set_header Authorization $auth_header;

        # Проксирование к Yandex Object Storage
        proxy_pass https://storage.yandexcloud.net/;
        proxy_set_header Host storage.yandexcloud.net;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        
        # Настройки для работы с большими файлами
        proxy_buffering off;
        proxy_request_buffering off;
        client_max_body_size 0;
        proxy_read_timeout 300s;
        proxy_connect_timeout 75s;
    }

    # Location для проверки аутентификации
    location = /oauth2/auth {
        internal;
        proxy_pass http://oauth2_proxy;
        proxy_pass_request_body off;
        proxy_set_header Content-Length "";
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

## Настройка Keycloak

После запуска контейнеров необходимо настроить Keycloak. Выполните следующие шаги:

1. Запустите контейнеры:
```bash
docker-compose up -d
```

2. Откройте браузер и перейдите по адресу `http://localhost:8080`. Войдите в административную консоль Keycloak с учетными данными admin/admin_password.

3. Создайте новый Realm с названием "yandex-s3".

4. В созданном Realm создайте нового клиента:
    - Client ID: yandex-s3-client
    - Client Protocol: openid-connect
    - Access Type: confidential
    - Valid Redirect URIs: https://yourdomain.com/oauth2/callback
    - Web Origins: https://yourdomain.com

5. Во вкладке "Credentials" скопируйте Secret и вставьте его в docker-compose.yml в переменную OAUTH2_PROXY_CLIENT_SECRET.

6. Создайте пользователей, которым будет разрешен доступ к S3.

## Настройка доступа к Yandex Object Storage

Для корректной работы с Yandex Object Storage необходимо настроить политики доступа. Создайте сервисный аккаунт в Yandex Cloud и назначьте ему необходимые права на бакет.

Для более гранулярного контроля доступа можно использовать следующий подход: создать отдельный location в Nginx для каждого бакета и проверять права доступа на основе групп пользователей в Keycloak.

Добавьте в `nginx/conf.d/default.conf`:

```nginx
# Доступ к конкретному бакету
location ~ ^/my-bucket/(.*) {
    auth_request /oauth2/auth;
    error_page 401 = /oauth2/sign_in;

    auth_request_set $user   $upstream_http_x_auth_request_user;
    auth_request_set $email  $upstream_http_x_auth_request_email;
    auth_request_set $groups $upstream_http_x_auth_request_groups;

    # Проверка принадлежности к группе
    if ($groups !~ "s3-users") {
        return 403;
    }

    # Добавление подписи AWS для Yandex Object Storage
    set $s3_bucket "my-bucket";
    set $aws_access_key "YOUR_ACCESS_KEY";
    set $aws_secret_key "YOUR_SECRET_KEY";

    proxy_pass https://storage.yandexcloud.net/$s3_bucket/$1$is_args$args;
    proxy_set_header Host storage.yandexcloud.net;
    proxy_set_header Authorization "AWS4-HMAC-SHA256 ...";
}
```

## Расширенная конфигурация oauth2-proxy

Для более детальной настройки oauth2-proxy можно создать отдельный конфигурационный файл. Создайте файл `oauth2-proxy.cfg`:

```ini
provider = "keycloak-oidc"
client_id = "yandex-s3-client"
client_secret = "your-client-secret"
redirect_url = "https://yourdomain.com/oauth2/callback"
oidc_issuer_url = "http://keycloak:8080/realms/yandex-s3"

email_domains = ["*"]
cookie_secret = "your-cookie-secret-32-bytes-long!!!"
cookie_secure = false
cookie_expire = "24h"
cookie_refresh = "1h"

http_address = "0.0.0.0:4180"
upstreams = ["http://nginx:80"]

pass_access_token = true
pass_authorization_header = true
set_authorization_header = true
skip_provider_button = true

# Логирование
logging_filename = "/var/log/oauth2-proxy.log"
standard_logging = true
auth_logging = true
request_logging = true

# Группы и права доступа
scope = "openid email profile groups"
allowed_groups = ["s3-users", "s3-admins"]
```

## Безопасность и рекомендации

При развертывании в продакшн-окружении обязательно учитывайте следующие моменты безопасности:

1. Используйте SSL/TLS сертификаты для всех соединений. Можно интегрировать Let's Encrypt через certbot или traefik.

2. Храните секретные ключи в защищенном хранилище, например, в Docker Secrets или внешнем секрет-менеджере.

3. Настройте файрвол для ограничения доступа к портам Keycloak и oauth2-proxy.

4. Регулярно обновляйте все компоненты системы.

5. Настройте мониторинг и логирование для отслеживания подозрительной активности.

## Отладка и устранение неполадок

Для отладки системы используйте следующие команды:

```bash
# Просмотр логов всех сервисов
docker-compose logs -f

# Проверка состояния контейнеров
docker-compose ps

# Проверка сетевого взаимодействия
docker-compose exec nginx ping oauth2-proxy
docker-compose exec oauth2-proxy ping keycloak

# Тестирование аутентификации
curl -v http://localhost/oauth2/auth
```

Частые проблемы и их решения:

1. Ошибка "Invalid redirect URI" - проверьте настройки Valid Redirect URIs в клиенте Keycloak.

2. Ошибка 502 Bad Gateway - убедитесь, что все сервисы запущены и доступны по сети.

3. Проблемы с куками - проверьте настройки cookie_secret и cookie_secure в oauth2-proxy.

## Масштабирование решения

Для обработки большого количества запросов можно масштабировать компоненты системы:

```yaml
services:
  nginx:
    image: nginx:alpine
    deploy:
      replicas: 3
    # остальная конфигурация

  oauth2-proxy:
    image: quay.io/oauth2-proxy/oauth2-proxy:v7.5.0
    deploy:
      replicas: 2
    # остальная конфигурация
```

Также рекомендуется использовать внешний балансировщик нагрузки и кеширование для улучшения производительности.

## Заключение

В этой статье мы рассмотрели комплексное решение для организации безопасного доступа к Yandex Object Storage через единую точку входа с использованием современных инструментов аутентификации и авторизации. Предложенная архитектура обеспечивает гибкий контроль доступа, масштабируемость и простоту управления. При правильной настройке и соблюдении рекомендаций по безопасности
