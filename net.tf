# Ресурс для создания сети VPC в Yandex Cloud
resource "yandex_vpc_network" "keycloak-oauth2-proxy-nginx" {
  name      = "vpc"  # Имя сети VPC
}

# Ресурс для создания подсети в зоне "ru-central1-a"
resource "yandex_vpc_subnet" "keycloak-oauth2-proxy-nginx-a" {
  v4_cidr_blocks = ["10.0.1.0/24"]  # CIDR блок для подсети (IP-диапазон)
  zone           = "ru-central1-a"  # Зона, где будет размещена подсеть
  network_id     = yandex_vpc_network.keycloak-oauth2-proxy-nginx.id  # ID сети, к которой будет привязана подсеть
}

# Ресурс для создания подсети в зоне "ru-central1-b"
resource "yandex_vpc_subnet" "keycloak-oauth2-proxy-nginx-b" {
  v4_cidr_blocks = ["10.0.2.0/24"]  # CIDR блок для подсети (IP-диапазон)
  zone           = "ru-central1-b"  # Зона, где будет размещена подсеть
  network_id     = yandex_vpc_network.keycloak-oauth2-proxy-nginx.id  # ID сети, к которой будет привязана подсеть
}

# Ресурс для создания подсети в зоне "ru-central1-d"
resource "yandex_vpc_subnet" "keycloak-oauth2-proxy-nginx-d" {
  v4_cidr_blocks = ["10.0.3.0/24"]  # CIDR блок для подсети (IP-диапазон)
  zone           = "ru-central1-d"  # Зона, где будет размещена подсеть
  network_id     = yandex_vpc_network.keycloak-oauth2-proxy-nginx.id  # ID сети, к которой будет привязана подсеть
}
