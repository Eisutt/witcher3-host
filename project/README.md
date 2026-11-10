# witcher3-host

Учебный pet-проект: облачная инфраструктура в Selectel, развёрнутая через Terraform, со стеком мониторинга, HTTPS и автоматическим деплоем через GitHub Actions.

На сервере работает статический сайт и веб-интерфейсы мониторинга. Nginx принимает весь входящий трафик и по доменному имени направляет запрос в нужный контейнер. Prometheus собирает метрики хоста и контейнеров, Grafana их показывает, а Alertmanager при сбое шлёт уведомление в Telegram.

> **Статус:** проект работал в Selectel с июня по август 2026 года. Сейчас инфраструктура удалена (`terraform destroy`), чтобы не платить за простаивающие ресурсы. Код и документация сохранены, всё разворачивается заново по инструкции ниже.

## Стек

| Область | Инструменты |
|---|---|
| Инфраструктура как код | Terraform (провайдеры `selectel` и `openstack`) |
| Облако | Selectel Cloud (OpenStack), регион ru-9 |
| ОС | Ubuntu 22.04 LTS |
| Контейнеризация | Docker, Docker Compose v2 |
| Веб-сервер | Nginx (reverse proxy), Let's Encrypt (Certbot, webroot) |
| Мониторинг | Prometheus, Grafana, Node Exporter, cAdvisor |
| Алертинг | Alertmanager → Telegram-бот |
| CI/CD | GitHub Actions (self-hosted runner), GitHub Secrets |

## Архитектура

```mermaid
flowchart LR
    User["Браузер пользователя"]
    GH["GitHub Actions"]
    TG["Telegram"]

    subgraph Selectel["Selectel Cloud: проект, приватная сеть 192.168.199.0/24, NAT-роутер, floating IP"]
        subgraph VM["ВМ Ubuntu 22.04"]
            Runner["Self-hosted runner"]
            subgraph Compose["Docker Compose, сеть monitoring_net"]
                Nginx{"Nginx<br>reverse proxy<br>80 / 443"}
                Site["Статический сайт"]
                Grafana["Grafana :3000"]
                Prometheus["Prometheus :9090"]
                Alertmanager["Alertmanager :9093"]
                NodeExp["Node Exporter :9100"]
                cAdvisor["cAdvisor :8080"]
                Certbot["Certbot"]
            end
        end
    end

    User -->|"HTTPS, по доменному имени"| Nginx
    Nginx --> Site
    Nginx -->|"grafana.*"| Grafana
    Nginx -->|"prometheus.*"| Prometheus
    Nginx -->|"alertmanager.*"| Alertmanager

    Prometheus -->|"scrape каждые 15 с"| NodeExp
    Prometheus -->|"scrape каждые 15 с"| cAdvisor
    Grafana -->|"PromQL"| Prometheus
    Prometheus -->|"алерты"| Alertmanager
    Alertmanager -->|"Bot API"| TG

    Certbot -.->|"сертификаты Let's Encrypt"| Nginx
    GH -->|"push в main"| Runner
    Runner -->|"docker compose up -d"| Compose
```

**Как проходит запрос.** Все DNS-записи (`@`, `www`, `grafana`, `prometheus`, `alertmanager`) указывают на один публичный IP. Nginx смотрит на заголовок `Host` и проксирует запрос в нужный контейнер по его имени внутри Docker-сети. Наружу опубликованы только порты Nginx (80 и 443).

## Структура репозитория

```
.
├── .github/workflows/deploy.yml        # пайплайн деплоя
└── project/
    ├── terraform/
    │   ├── main.tf                     # сеть, роутер, ВМ, диск, floating IP
    │   └── variables.tf                # переменные (значения в terraform.tfvars, не в Git)
    ├── docker/
    │   ├── docker-compose.yml          # все сервисы
    │   ├── html/                       # статический сайт
    │   └── configs/
    │       ├── nginx/nginx.conf
    │       ├── prometheus/             # prometheus.yml, alerts.yml
    │       ├── alertmanager/           # alertmanager.example.yml (боевой генерируется в CI)
    │       └── certbot/                # сертификаты (в .gitignore)
    ├── .gitlab-ci.yml                  # первая версия пайплайна, до переезда на GitHub Actions
    └── .gitignore
```

## Как развернуть

### 1. Инфраструктура (Terraform)

Terraform создаёт в Selectel:
- отдельный проект и сервисного пользователя с ролью `member`;
- приватную сеть и подсеть `192.168.199.0/24`;
- облачный роутер с выходом в интернет (NAT);
- сетевой порт, загрузочный сетевой диск 20 ГБ и ВМ (1 vCPU, 1 ГБ RAM);
- floating IP, привязанный к порту ВМ.

В Selectel используются два провайдера: `selectel` управляет аккаунтом (проекты, пользователи, ключи), а `openstack` управляет ресурсами внутри проекта (сети, диски, ВМ).

Создайте `project/terraform/terraform.tfvars` (файл в `.gitignore`):

```hcl
sel_domain                   = "<номер аккаунта Selectel>"
sel_username                 = "<пользователь панели>"
sel_password                 = "<пароль>"
sel_service_account_username = "<имя сервисного пользователя>"
sel_service_account_password = "<пароль сервисного пользователя>"
```

Затем:

```bash
cd project/terraform
terraform init
terraform plan
terraform apply      # в конце выведет public_ip_address
```

### 2. Домен и DNS

В DNS-хостинге Selectel создаются A-записи `@`, `www`, `grafana`, `prometheus` и `alertmanager` на публичный IP сервера. Для зоны `.ru` домен делегируется только после подтверждения телефона владельца. Статус можно проверить так:

```bash
whois <домен>    # нужно: state: REGISTERED, DELEGATED, VERIFIED
```

### 3. Базовая защита сервера

- создан непривилегированный пользователь с `sudo`;
- вход только по SSH-ключу;
- в `/etc/ssh/sshd_config` заданы `PermitRootLogin no` и `PasswordAuthentication no`.

После изменения `sshd_config` текущую root-сессию не закрываем, пока не проверим вход под новым пользователем во втором окне. Иначе можно потерять доступ к серверу.

### 4. Docker

```bash
sudo apt update
sudo apt install -y docker.io docker-compose-v2
sudo usermod -aG docker $USER    # затем перелогиниться
```

### 5. HTTPS

Сертификат Let's Encrypt выпускается Certbot'ом через webroot: Certbot кладёт проверочный файл в общий том, а Nginx отдаёт его по пути `/.well-known/acme-challenge/`.

На старте сертификатов ещё нет, а Nginx с `listen 443 ssl` без них не запустится. Поэтому сначала Nginx поднимается с HTTP-конфигом, затем выпускается сертификат, и только потом включается HTTPS-конфиг из репозитория:

```bash
docker compose run --rm certbot certonly --webroot --webroot-path /var/www/certbot/ \
  -d <домен>,www.<домен>,grafana.<домен>,prometheus.<домен>,alertmanager.<домен>
```

Перед настоящим выпуском удобно проверить пути с флагом `--dry-run`.

В итоговом конфиге порт 80 обслуживает только ACME challenge и `301` редирект на HTTPS, а вся работа идёт через 443.

### 6. CI/CD

1. На сервере установлен GitHub Actions runner и запущен как systemd-сервис (`./svc.sh install && ./svc.sh start`).
2. В **Settings → Secrets and variables → Actions** заданы секреты:
   - `PROD_ENV`: содержимое `.env` для Docker Compose (логин и пароль Grafana);
   - `TG_BOT_TOKEN`, `TG_CHAT_ID`: доступ бота к чату для алертов.
3. При каждом push в `main` пайплайн:
   - забирает код;
   - создаёт `.env` и `alertmanager.yml` из секретов (в репозитории их нет);
   - копирует сертификаты в рабочую папку runner'а;
   - перезапускает стек командой `docker compose up -d`.

### 7. Проверка алертинга

```bash
docker stop nginx
```

Примерно через минуту в Telegram приходит `🚨 СБОЙ: NginxContainerDown`, а после `docker start nginx` приходит сообщение о восстановлении.

## Мониторинг

- **Node Exporter** собирает метрики хоста: CPU, память, диск, сеть. В Grafana для них импортирован дашборд [Node Exporter Full](https://grafana.com/grafana/dashboards/1860) (ID 1860).
- **cAdvisor** собирает метрики контейнеров.
- **Prometheus** опрашивает обе цели каждые 15 секунд и проверяет правила из `alerts.yml`.
- **Правило `NginxContainerDown`** срабатывает, если cAdvisor не видел контейнер `nginx` больше 60 секунд или метрика пропала совсем (`absent`).
