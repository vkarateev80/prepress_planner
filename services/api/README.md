# Сервис `api` — проекты и файлы в облаке (control plane SaaS)

Основание: **System Design v1 (approved)** — ADR-5 (гибрид S3 + PostgreSQL),
ADR-6 (единый origin, nginx), ADR-7 (конвертер отдельным сервисом), §3.3/§3.4
(потоки и границы), §12.4/§12.5 (контракты проектов и файлов), §13.3 (модель
данных); **PRD v2** — F-1…F-4 (разбор/конвертация/русские ошибки), N-4
(изоляция аккаунтов), §3 фазы 1–3.

`api` — **единственный** владелец оркестрации и персистентности: пишет в
PostgreSQL (метаданные, версии, отчёты) и в S3-совместимое объектное хранилище
(blobs ≤ 50 МБ), авторизует каждый запрос через `auth POST /auth/verify`,
вызывает конвертер сервер-к-серверу. `packages/core` этот сервис не трогает:
домен исполняет `domain-worker` (следующая задача).

- **Зависимости**: `fastapi`, `uvicorn`, `python-multipart`, `pydantic`,
  `psycopg2-binary` (только для `DB_URL=postgresql://`).
- **S3-подпись и все внутренние HTTP-вызовы — стандартная библиотека**
  (`urllib`, `hashlib`, `hmac`): `boto3` не требуется.
- **Публичный bucket запрещён**: чтение — поток через API либо короткоживущий
  presigned URL (`PP_PRESIGN_TTL`, по умолчанию 300 с).

## Запуск

```bash
# dev-стек сервисов (SQLite, хранилище в памяти):
cd services && cp .env.example .env && docker compose up -d --build
curl -s http://127.0.0.1:8100/healthz | head -c 400

# dev-стек с гибридным хранилищем (MinIO):
docker compose --profile storage up -d --build
#   PP_STORAGE_BACKEND=s3 OBJECT_STORAGE_ENDPOINT=http://minio:9000
#   OBJECT_STORAGE_PUBLIC_ENDPOINT=http://127.0.0.1:9010

# прод-стек (PostgreSQL + MinIO + nginx TLS 443):
cd deploy && cp .env.example .env && docker compose up -d --build
```

Тесты (внешние сервисы не вызываются — фейки вместо auth/конвертера):

```bash
cd services/api && python3 -m pytest tests -q          # 33 теста
# против реального PostgreSQL (проверка переносимости схемы):
PP_TEST_DB_URL=postgresql://pp_user:pp_secret@localhost:5432/prepress_saas \
  python3 -m pytest tests -q
```

## Гибридное хранилище (ADR-5)

| Что | Где | Ключ/столбец |
|---|---|---|
| Blob (исходник, конвертированный SVG/PDF, отчёт) | объектное хранилище (MinIO/S3) | `org/{org_id}/project/{project_id}/file/{file_id}/{version}/{sha256}/{name}` |
| Метаданные, владение, версии, checksum | PostgreSQL | `projects`, `files`, `file_versions`, `reports` |
| Отчёты | объектное хранилище | `org/{org_id}/project/{project_id}/report/{report_id}/{sha256}/{name}` |

Двойной рубеж изоляции (N-4): `org_id` есть **в каждой строке** БД, и все
выборки фильтруются по нему (`WHERE org_id = ?`), а ключ объекта начинается с
префикса организации. Проверка membership берётся из `auth /auth/verify`, а не
из параметров запроса: `?org_id=` чужого тенанта даёт `403 forbidden_org`.

Версии: `file_versions` — история (UNIQUE `file_id, version`); при превышении
`PP_MAX_FILE_VERSIONS` старые версии мягко удаляются (`deleted_at`), а их
объекты удаляются из хранилища. Мягкое удаление проекта/файла (`DELETE`)
проставляет `deleted_at` + `updated_at` и **не** удаляет объекты.

`projects.state_json` хранит состояние проекта (`project_state.json v2`) прямо
в БД. Если состояние вырастет выше лимита (крупные массивы геометрии), в
`state_json` кладётся ссылка `{"storage_key": "…"}` на объект в хранилище —
колонка `state_json_blob` остаётся совместимой (сейчас она GENERATED-алиас).

## Модель данных (§13.3)

```sql
-- projects: проект организации; state_json — состояние project_state.json v2
projects(id PK, org_id, name, created_by, created_at, updated_at, deleted_at,
         state_json JSONB,            -- state_json_blob GENERATED AS (state_json)
         INDEX (org_id), INDEX (org_id, name))

-- files: логический файл проекта (file_type — из task-spec, source_kind — §13.3)
files(id PK, org_id, project_id, name, original_name GENERATED AS (name),
      file_type TEXT,                 -- original|converter_result|healed_master|array|result|report
      source_kind TEXT,               -- uploaded|converted|generated
      mime, size_bytes BIGINT, checksum_sha256, storage_key,
      version INT, parent_file_id, created_by,
      created_at, updated_at, deleted_at,
      INDEX (org_id), INDEX (org_id, project_id), INDEX (parent_file_id))

-- file_versions: каждая версия — свой объект в S3 со своим sha256
file_versions(id PK, file_id, org_id, version INT, storage_key,
              checksum_sha256, size_bytes, mime,
              kind TEXT,              -- original|converted|healed|master|array|report
              geometry JSONB, created_by, created_at, updated_at, deleted_at,
              UNIQUE(file_id, version), INDEX (org_id, file_id))

-- reports: PDF/XLSX/DXF-отчёты (тоже объекты)
reports(id PK, org_id, project_id, file_id, kind TEXT CHECK(kind IN ('pdf','xlsx','dxf')),
        report_type GENERATED AS (kind), storage_key, checksum_sha256, size_bytes,
        created_by, generated_at, created_at, updated_at, deleted_at,
        INDEX (org_id), INDEX (org_id, project_id))

-- price_catalogs (§12.7): реализован как служебный проект org с name='price_catalog',
-- state_json = {catalog: PriceCatalog} (отдельная таблица появится вместе с расчётами)
```

В PostgreSQL: `JSONB`, `BIGINT`, `BOOLEAN`, плюс `timestamptz`-алиасы
(`created_at_ts`, `updated_at_ts`) рядом с переносимыми ISO-8601 `TEXT`
(схема совпадает с `services/payments/payments_app/db.py`, чтобы обе части
стекa читали одни и те же `organizations/users`). SQLite используется для dev
и тестов; PostgreSQL — целевая СУБД (§13).

## API

Аутентификация: `Authorization: Bearer <токен>` → `auth POST /auth/verify` →
`{sub, email, orgs:[{org_id, role}]}`. Роли: `owner/admin` — удаление,
`member` — создание/загрузка, `viewer` — чтение. Единый конверт ошибок:
`{"error": {"code", "message", "details?"}}`, сообщения — русские (§12.1).

| Метод/путь | Запрос | Ответ |
|---|---|---|
| `POST /api/projects` | `{name, org_id?, state?}` | `201 {project_id, state, project, org_id}` |
| `GET /api/projects` | `?org_id&limit&offset` | `200 {items:[project], total}` |
| `GET /api/projects/{id}` | — | `200 {project, files, versions}` (метаданные, без содержимого) |
| `PATCH /api/projects/{id}` | `{name?, state?}` | `200 {project}` |
| `DELETE /api/projects/{id}` | — | `204` (мягкое удаление: `deleted_at`) |
| `POST /api/projects/{id}/files` | multipart `file` (+ `convert`, `convert_target`, `file_type`) | `201 {file_id, storage_key, checksum, version, file, converted…}` |
| `GET /api/projects/{id}/files` | — | `200 {items:[file], total}` |
| `GET /api/projects/{id}/files/{file_id}` | — | `200 {file, versions}` |
| `POST /api/projects/{id}/files/{file_id}/convert` | `?target=svg\|pdf&sync=1` | `202 {job_id}` / синхронно `{converted_file_id, …}` |
| `GET /api/files/{file_id}` | — | `200 {file, versions}` |
| `GET /api/files/{file_id}/download` | `?mode=stream\|presigned&version=` | поток (200) или `{url, expires_in}` |
| `GET /api/files/{file_id}/content` | `?format=svg\|pdf\|original` | поток/ссылка на конкретную версию |
| `DELETE /api/files/{file_id}` | — | `204` (мягкое удаление) |
| `GET /api/jobs/{job_id}` | — | `200 {status: pending\|running\|done\|error, result?, error?}` |
| `POST /api/projects/{id}/calc` | `{layout_params, file_version_id?}` | `200 {calc: MaterialResult, state, reference}` (§12.6, F-10) |
| `POST /api/projects/{id}/variants` | `{layout_params, limit?}` | `200 {variants: [MaterialResult], total, selected_variant_index}` (F-11) |
| `POST /api/projects/{id}/teo` | `{layout_params, teo_input}` | `200 {teo: TeoResult, comparison, state}` (F-14) |
| `POST /api/projects/{id}/teo/compare` | `{layout_params, teo_input}` | `200 {comparison: {best_index, best_cost_per_1000, savings…}}` (F-15) |
| `POST /api/projects/{id}/pipeline` | `{file_id?, file_version_id?, layout_params, teo_input?, catalog?}` | `200 {state, result, metrics, reference}` (§12.6, §3.3 С5) |
| `POST /api/projects/{id}/calculate` | то же | синоним `/pipeline` (UI-путь «рассчитать») |
| `GET /api/projects/{id}/reports` | — | `200 {items:[report]}` |
| `GET /api/reports/{id}` / `/api/reports/{id}/download` | — | метаданные + `download_url` / поток |
| `GET /api/orgs/{org_id}/catalog` / `PUT` | `{catalog}` | `200 {catalog}` |
| `GET /healthz` | — | статус, БД, хранилище, лимиты, таблицы |

Пути `/api/...` и `/api/v1/...` (§12.4) эквивалентны: nginx срезает префикс
`/api`, а middleware сервиса нормализует `/v1` — контракт работает и из
браузера (same origin), и при прямом обращении к 8100 в dev.

Ошибки: `400/422` валидация (неподдерживаемый формат, несоответствие
`content-type`), `401` нет/невалидный токен, `403` нет прав/лимит тарифа,
`404` чужой тенант или отсутствующий объект, `413` файл больше `PP_MAX_MB`,
`503` недоступно объектное хранилище.

Проверено вживую (`uvicorn` + фейковый auth + заглушка контракта конвертера):
`POST /api/projects` → `POST /api/projects/{id}/files` (SVG, AI, CDR) →
синхронная и асинхронная конвертация → `GET /api/files/{id}/download`
(поток с `X-PP-Checksum-Sha256`) и `?mode=presigned` → `DELETE` (soft delete,
`deleted_at` в БД, blob на месте) → русские ошибки `422/404`. Прогон реального
`services/converter` в этой среде невозможен: его код требует Python 3.10+
(в Docker — 3.12), локально доступен 3.9.

## Доменные расчёты через `domain-worker` (§12.6, ADR-2)

`api` **не исполняет домен сам**: он проверяет членство/роль (N-4), при
необходимости достаёт байты объекта из хранилища и вызывает `domain-worker`
(`POST /calculate`, внутренний 8101) сервер-к-серверу. Перевод контракта
`api_app/domain.py`: `layout_params`/`teo_input` (snake_case §12.6) →
`params`/`teoInput` (`project_state.json v2`, camelCase). Ответ воркера —
канонический state v2, без пересчёта на стороне `api`.

Стадии: с макетом (`file_id`/`file_version_id`) — вся цепочка
(`parse → analyze → heal → pattern → calc → variants → teo`); без макета —
расчётная часть (`calc → variants → teo`), потому что эталонный сценарий
PRD §10.2 задаётся только параметрами раскроя.

Живая сверка эталона (реальный Dart-воркер, без моков):

```bash
bash scripts/run_api_e2e.sh     # api → domain-worker → packages/core
```

Скрипт поднимает воркер на 8199, создаёт проект через `POST /api/projects` и
вызывает `POST /api/projects/{id}/calculate` с `W=50, H=30, gap=3, Z=96,
CP=3.175, cyl=web=300, mode=count, count=5000`: получены `9×5`, `5040`, `112`,
`34137.6`, `26.18`, `2032.0`, `304.8`, `costPer1000=704.88`, `totalCost=3552.58`,
`machineCost=2528.45`, `materialCost=1024.13`, `runTimeHours=0.0057` — **delta =
0.0** по всем полям, `metrics.reference.passed = true`.

Тесты без сети (фейковый воркер, конвенция `test_api_projects.py`):
`services/api/tests/test_api_domain.py` — 19 тестов (перевод контракта,
эндпоинты, изоляция тенантов, base64 макета, русские ошибки воркера).

## Загрузка файла (F-1…F-4)

1. Bearer → `auth/verify`, организация из выдачи; проект ищется с фильтром
   `org_id` (чужой → `404`).
2. Проверка расширения (`.dxf .svg .pdf .ai .cdr .eps`) и `content-type`;
   размер ≤ `PP_MAX_MB` (50 МБ) — читается потоково, при превышении `413`
   с русским сообщением (nginx допускает 64m с запасом).
3. Объект пишется в хранилище, метаданные — в `files` + `file_versions` v1
   (`sha256`, `size_bytes`, `storage_key`), ответ содержит `file_id`,
   `storage_key`, `checksum`.
4. Для **AI/CDR/EPS** (или `convert=1`) `api` вызывает конвертер
   `POST /convert` → `GET /convert/{id}` → забирает результат из staging и
   кладёт его **отдельным файлом** `file_type=converter_result`,
   `source_kind=converted`, `parent_file_id=<original>`; исходник остаётся для
   аудита. Браузер конвертер не вызывает (ADR-7).
   - `convert=svg|pdf` — конвертация **синхронно** в том же ответе
     (`converted_file_id`, `converted_storage_key`, `converter_status`);
   - закрытый формат без явного `convert` — конвертация **асинхронно**
     (`202`-семантика: `converted: true, async: true, job_id`,
     статус — `GET /api/jobs/{job_id}`), чтобы 50-МБ макет не упирался в
     таймаут nginx (220 с).

## Переменные окружения

| Переменная | Назначение | По умолчанию |
|---|---|---|
| `PP_AUTH_URL` | адрес auth (обязателен) | — |
| `DB_URL` | `postgresql://…` (иначе SQLite в `PP_DATA_DIR`) | пусто → SQLite |
| `PP_BILLING_URL` | entitlement-гейтинг (§12.3) | `http://billing:8122` |
| `CONVERTER_URL` | внутренний конвертер (ADR-7) | `http://converter:8120` |
| `DOMAIN_WORKER_URL` | домен-воркер (§12.6, ADR-2) | `http://domain-worker:8101` |
| `OBJECT_STORAGE_ENDPOINT` | S3-endpoint | `http://minio:9000` |
| `OBJECT_STORAGE_PUBLIC_ENDPOINT` | endpoint для presigned URL (edge `/s3/`) | = endpoint |
| `OBJECT_STORAGE_BUCKET` / `_PREFIX` | bucket / префикс ключей | `prepress-saas` / `org` |
| `OBJECT_STORAGE_ACCESS_KEY` / `_SECRET_KEY` | ключи S3 | `minioadmin` (dev) |
| `PP_STORAGE_BACKEND` | `s3` \| `memory` (только тесты/dev) | `s3` |
| `PP_MAX_MB` | лимит размера файла | `50` |
| `PP_PRESIGN_TTL` | TTL presigned-ссылки, с | `300` |
| `PP_MAX_FILE_VERSIONS` | сколько версий хранится | `20` |
| `PP_AUTH_REQUIRED` | `1` — обязательный Bearer | `1` |
| `PP_ENTITLEMENT_ENFORCE` | `1` — спрашивать billing о лимите проектов | `1` (прод) / `0` (dev) |
| `PP_DEV_ORG_ID` / `PP_DEV_USER_ID` | тенант при `PP_AUTH_REQUIRED=0` | `org-dev` / `user-dev` |

Секреты — только env/секрет-менеджер; в ответах и `/healthz` их нет.

## Что осталось (следующие задачи)

- **`domain-worker`** (сделано в `e2e-calculation-path`): `api_app/domain.py`
  + эндпоинты §12.6 (`calc`/`variants`/`teo`/`teo/compare`/`pipeline`/
  `calculate`) подключены к воркеру 8101; эталон PRD §10.2 сверен вживую
  (`scripts/run_api_e2e.sh`, delta 0.0).
- **Отчёты** (§12.8): таблица и раздача (`GET /api/reports/...`) есть; вывод
  PDF/XLSX/DXF доменом подтверждён (`services/domain-worker/tool/verify_reports.dart`,
  22 проверки), но **генерация отчёта по запросу API ещё не подключена**
  (`POST /api/projects/{id}/reports/{pdf|xlsx|dxf}` → сохранение в хранилище
  + запись в `reports`) — следующая задача.
- **`flutter-web-adapt`**: перевод UI на `/api/projects/...` (picker →
  multipart → метаданные), серверный путь конвертации вместо прямого
  `/convert` из браузера, blob-скачивание через `GET /api/files/{id}/download`.
- **Эксплуатация**: TLS-сертификаты (`deploy/nginx/certs`), тест против
  реального PostgreSQL (`PP_TEST_DB_URL`), ретеншен/бэкап bucket (lifecycle),
  проверка nginx-конфига `nginx -t` (в текущей среде Docker недоступен).
