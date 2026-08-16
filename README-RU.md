# rw-backup-verify — автономная проверка логических бэкапов

Отдельный проект для сервера-песочницы. **Не связан** с веб-парком, SSH на прод
и `fleet.json` из `rw-backup-full`.

## Как работает

1. Глобальное расписание (`verify.interval_hours` или `verify.times`) — одна частота на все хранилища.
2. В это время обходятся **все** S3-записи: глубокий рекурсивный обход prefix.
3. В любой вложенности ищутся архивы `remnawave_backup_*.tar.gz` и `custom_bot_*.tar.gz`.
4. В каждой папке экземпляры группируются по семейству имён (панель / каждый бот-проект).
5. Берётся **только latest** каждого экземпляра; если этот ключ уже в `tested/` — пропуск.
6. Очередь FIFO: все due-экземпляры выполняются **строго по одному**.
7. Подробный отчёт в Telegram.

`backup_hint` у хранилища — только подсказка, как часто бэкапы **создаются** на проде.

## Раскладка в S3 (гибкая)

Поддерживается и канон `rw-backup-full`, и произвольная вложенность:

```
s3://bucket/<prefix>/panel/<source>/remnawave_backup_….tar.gz
s3://bucket/<prefix>/custom-bot/<source>/custom_bot_<proj>_….tar.gz
s3://bucket/<prefix>/clients/acme/panel/remnawave_backup_….tar.gz
s3://bucket/<prefix>/clients/acme/bots/custom_bot_bot1_….tar.gz
s3://bucket/<prefix>/clients/acme/bots/custom_bot_bot2_….tar.gz
```

В одной папке могут лежать архивы с разных серверов/проектов — каждый
`custom_bot_<имя>_…` и `remnawave_backup_…` = отдельный экземпляр.

## Быстрый старт

```bash
sudo ./install.sh

rw-backup-verify storage add \
  --id cf-oneok --endpoint https://... --bucket oneok \
  --access-key ... --secret-key ... --prefix oneok-wal \
  --backup-hint "прод: ежедневно 03:00"

rw-backup-verify schedule set --interval-hours 12
# или: rw-backup-verify schedule set --times 06:30,18:30

rw-backup-verify telegram set --token <bot> --chat-id <id>
# алиасы: tel / tg
rw-backup-verify discover cf-oneok          # что будет тестироваться
rw-backup-verify run --storage cf-oneok     # сейчас
```

## Один прогон на хост

Таймер тикает **раз в минуту**, но это лишь проверка расписания. Все длительные
и разрушающие команды (`run`, `tick`, `queue work`, `reclaim`, `runs prune`)
держат общий лок `work_dir/locks/global.lock`:

- `run --due` при занятом локе тихо пропускает слот (в журнале — одна строка);
- ручной `run` отказывается с подсказкой (`--wait <сек>` — подождать);
- `reclaim` отказывается (`--force` — убрать только то, что не принадлежит
  живому прогону).

Второй рубеж — реестр `work_dir/locks/active/<pid>.json`: пока прогон жив, его
песочница `rbv_pg_*`, compose-проект и каталог `runs/<id>` **не удаляются**
никакой уборкой, включая `reclaim --force` и `runs prune --keep 0`.

> Историческая причина: раньше `run` и `reclaim` безусловно делали
> `docker rm -f rbv_pg_*`, а таймер мог запустить их поверх идущего прогона.
> Живой restore терял БД и получал `rc=137` — но это был **не OOM**:
> `OOMKilled=false` + `State.Status=removing` = подпись внешнего `docker rm -f`.
> Слот расписания теперь занимается в начале прогона, иначе многочасовой run
> остаётся «due» и таймер дёргает его каждую минуту.

## Restore: чем закончился и почему

`psql` работает с `ON_ERROR_STOP=0`, поэтому его `rc` сам по себе ничего не
доказывает. Restore пишет внутри контейнера маркер `RBV_PSQL_RC=<rc>`; если
маркера нет — restore оборвали, и прогон не выдаёт «половину таблиц» за успех.

| class | смысл | что делать |
|---|---|---|
| `ok` | дамп применён целиком | — |
| `external` | песочницу удалили снаружи (`docker rm -f`) | ищите параллельный прогон/уборку; RAM ни при чём |
| `oom` | `OOMKilled=true` | swap ≥2G на хосте verify |
| `disk` | ENOSPC во время restore | `rw-backup-verify reclaim --docker` |
| `dead` / `start_failed` | postgres не поднялся или упал | `docker logs rbv_pg_*` |
| `psql_error` | psql вернул ошибку | `runs/<id>/psql.err` |

Всё, кроме `ok`, помечает прогон **retryable** (exit 75): архив не попадает в
`tested/`, следующий запуск возьмёт тот же ключ. При незавершённом restore
data-проверки помечаются `skip` — раньше они рапортовали «нет таблицы users»,
хотя дамп был цел.

**Какая БД проверяется.** Дампы ботов — обычно `pg_dumpall`: приложение живёт в
своей базе (`vpnbot` и т.п.), а в `postgres` пусто или лежит служебная мелочь.
Выбирается самая содержательная БД — сначала та, где есть `public.users`, затем
по числу таблиц; `POSTGRES_DB` из `PROFILE.env` имеет приоритет. Список
кандидатов пишется в отчёт:

```
db_schema: db=vpnbot user_tables=23 (кандидаты: vpnbot=23+users)
```

Роли из дампа (`OWNER TO` / `GRANT … TO` / `AUTHORIZATION`) создаются в
песочнице заранее, иначе restore сыплет `role "…" does not exist`.
Параметры Postgres подбираются под доступную RAM, `fsync`/`full_page_writes`/
`synchronous_commit` выключены — песочница одноразовая, и это кратно ускоряет
restore крупных дампов.

## Проверки (включаются/выключаются раздельно для panel и bot)

В `/etc/rw-backup-verify/config.json` → `checks.panel` / `checks.bot`:

| Ключ | Смысл |
|---|---|
| `bot_users` | **bot:** группа «пользователи» — `users`, `subscriptions`, `tariffs`, `app_settings`, `cabinet_email_verification_codes`, `cabinet_site_visits` |
| `bot_payments` | **bot:** группа «платежи» — `payments`, `payment_intents`, `payment_webhook_events`, `recurring_yookassa`, `recurring_robokassa` |
| `user_rows` | **panel:** таблица пользователей по эвристике; не пуста и ≥ предыдущей проверки |
| `event_freshness` | **bot:** самая свежая дата среди платёжных таблиц бота (если платежей нет — среди пользовательских); **panel:** users/nodes. Окно [prev_backup − skew … curr_backup + skew] |
| `stack` | поднять compose в `--internal` + без падений `stability_seconds` |
| `isolation` | сеть `Internal=true` + нет внешнего TCP egress (DNS на internal часто резолвится — это не leak). **Preflight** до download: если хост не изолирует — все тесты стоп. В stack — до stability/ports. |
| `backend_ports` | TCP/HTTP к портам сервисов, ответ не пустой |

### Данные бота: две группы

Набор таблиц у ботов разный, поэтому **отсутствие таблицы — не ошибка**: у бота
просто нет такой функции. Ошибка — это **пропажа данных**:

| Ситуация | Итог |
|---|---|
| таблицы нет и раньше не было | ⚪ `absent` — норма |
| таблица есть, строк столько же или больше | ✅ `ok` |
| таблица есть впервые | ✅ `new` — записывается в baseline |
| таблица пустая, истории нет | ⚪ `empty` (кроме `users` — бот без пользователей это ❌) |
| **строк стало меньше, чем в прошлой проверке** | ❌ `drop` |
| **таблица была с данными и исчезла** | ❌ `gone` |

В отчёт попадает построчная сводка и итог по группе:

```
✅ bot_users — 4/6 таблиц, строк=2169420 · users=2169069 subscriptions=320 … · нет: cabinet_site_visits
✅ bot_payments — 3/5 таблиц, строк=88214 · payments=51120 payment_webhook_events=37094 …
```

Счётчики строк по каждой таблице хранятся в baseline экземпляра, поэтому
сравнение идёт с предыдущим **проверенным** бэкапом именно этого бота.

Переопределить состав групп (например, у бота свои имена таблиц):

```json
"checks": { "bot": { "tables": {
  "users":    ["users", "subscriptions"],
  "payments": ["payments"]
} } }
```

Если у бота нет ни одной таблицы из обеих групп — это ошибка (значит выбрана не
та БД или дамп пустой), и при **ручном** `run` в report и в
`work_dir/logs/schema_*.txt` печатается **полный schema-diag** (все таблицы,
поля, rows).

`timezone_skew_hours` (по умолчанию 14) — допуск на разные TZ серверов.

Старые имена `db_rows` / `user_rows_monotonic` / `stack_up` / `stability` ещё читаются как алиасы.

Отключить пример:
```json
"checks": { "bot": { "backend_ports": false, "stack": false } }
```

## Telegram-отчёт

- хранилище, полный S3-путь, id экземпляра
- список проверок с ✅/❌/⚠️/⚪ и значениями prev→curr
- блок «Расхождения» при fail
- при ошибке — второе сообщение с логами контейнеров

## Восстановление при тесте

| Вид | Основа | Шаги |
|---|---|---|
| **panel** | dump-path verify-stack | `dump_*.sql.gz` + `remnawave_dir_*.tar.gz` → PG + isolate compose |
| **bot** | `custom-restore` | PROFILE + postgres dump + redis RDB → isolate |

Изоляция: сеть `--internal`, без published ports / docker.sock / external nets.

## Команды

```
rw-backup-verify storage list|add|remove|show
rw-backup-verify schedule show|set
rw-backup-verify telegram|tel|tg set|show
rw-backup-verify discover <id> [--all]
rw-backup-verify run [--due] [--storage ID]
rw-backup-verify queue status|clear|work
rw-backup-verify tick
```

Конфиг: `/etc/rw-backup-verify/config.json`  
Состояние tested: `/var/lib/rw-backup-verify/tested/<storage>.json`

Тесты (без Docker/S3):

```bash
bash test/unit_config_queue.sh    # конфиг, расписание, очередь
bash test/unit_logic_full.sh      # discover/tested/CLI/compose rewrite
bash test/unit_concurrency.sh     # лок, реестр активных, защита от уборки
bash test/unit_hardening.sh       # errexit/pipefail-ловушки, tunables, пороги
bash test/unit_bot_groups.sh      # группы данных бота, сверка с baseline
```

Живой e2e (нужен рабочий Docker; сам собирает синтетический bot-архив,
поднимает postgres, стек в `--internal` и имитирует внешний `docker rm -f`):

```bash
bash test/live_pg_restore.sh
```

Ручной `run` пишет шаги в stderr и в `work_dir/logs/run_*.log`
(по умолчанию `/var/lib/rw-backup-verify/logs/`). Отчёты прогонов —
`work_dir/runs/<id>/`. Архивы кэшируются в `work_dir/cache/archives/`
(повторный прогон не качает S3). В `runs/<id>/` также лежат дампы compose
из бэкапа и isolated-версии (`compose.from-backup*`, `compose.isolated*`,
`compose.ps.txt`, `compose.logs.txt`) — для ручной корректировки инфры.

Panel (Remnawave): compose обычно схож, отличается в основном расположением БД
(URL переписывается на sandbox `remnawave-db`). Bot: схемы разные (swarm/
`BACKEND_IMAGE`, infra-compose и т.д.) — смотрите дамп; без image tags в архиве
stack будет skip.

Освободить диск:

```bash
rw-backup-verify disk
rw-backup-verify reclaim --docker   # runs+cache latest + volumes/containers (образы остаются)
                                    # во время прогона откажется; --force чистит только чужое
```

Политика хранения:
- **архивы** в `cache/archives/` — только latest на экземпляр, как скачаны из S3
  (без доп. шифрования); остальное удаляется на каждом run/tick;
- **контейнеры/volumes** — удаляются после каждого теста (`down -v` + volume prune);
- **образы** — сохраняются; при смене тега в compose бэкапа — `compose pull`;
- **PG sandbox** (`rbv_pg_*`) без `-v` на хост; `/var/lib/postgresql` на хосте ≠ rbv.
- Артефакты **живого** прогона уборка не трогает (см. «Один прогон на хост»);
  `rc=137` при `OOMKilled=false` — это внешнее удаление контейнера, не нехватка RAM.
- Хост verify с **~4 GiB RAM**: для dump 200–500 M нужен **swap ≥2G**, иначе SIGKILL 137.
  После тестов rbv сбрасывает page cache (`drop_caches`) — иначе `buff/cache` от
  чтения dump держит RAM, хотя `docker ps` пуст.

```bash
fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
echo '/swapfile none swap sw 0 0' >> /etc/fstab
free -h
rw-backup-verify reclaim --docker   # + mem reclaim
```

После каждого job тяжёлые `extract/`/sql из `runs/<id>/` удаляются автоматически
(остаются report + compose.*); перед большим restore — gate ≥max(1.5 GiB, 4×sql.gz).

**Кэш архивов** (`work_dir/cache/archives/`): при **каждом** `run` и `tick`
(ручной = по расписанию) старые скачанные удаляются; остаётся **только последний
на экземпляр** — для повторного ручного прогона без S3.

```bash
rw-backup-verify run --storage tw-oneok
rw-backup-verify cache list
rw-backup-verify cache prune [--storage tw-oneok]   # вручную то же правило
```
