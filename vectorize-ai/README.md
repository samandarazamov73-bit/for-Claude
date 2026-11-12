# Vectorize AI

Веб-сервис и REST API для перевода растровых изображений (PNG, JPEG, GIF, BMP, WebP, TIFF) в векторную графику (SVG, PDF, EPS, DXF, PNG). Реализация написана с нуля по функциональному описанию из технического разбора Vectorizer.AI: код, бандлы и внутренние протоколы оригинала не использовались.

- **Движок** — многоэтапный классический конвейер: сегментация цветов с учётом сглаживания, линейные и радиальные градиенты вместо полос, общий для соседних фигур граф границ (Vector Graph), субпиксельные границы, кривые Безье и дуги, восстановление углов, распознавание фигур, симметрия и повторы.
- **Веб-приложение** — загрузка (drag&drop, диалог, Ctrl+V, URL), Pre-Crop, живой прогресс, редактор с 7 инструментами, Before/After, экспорт.
- **Бэкенд** — FastAPI, очередь задач с пулом процессов, аккаунты, подписка и кредиты, публичный API с OpenAPI 3.0.3 и Swagger UI.

Подробнее: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) · [docs/IMPLEMENTATION_PLAN.md](docs/IMPLEMENTATION_PLAN.md)

## Быстрый старт

Требования: Python 3.11+, Node.js 20+.

```bash
cd vectorize-ai
pip install -e ".[dev]"                 # зависимости бэкенда и движка
(cd frontend && npm install && npm run build)
python -m backend --port 8000           # http://localhost:8000
```

Сервер отдаёт собранный фронтенд, API (`/api/...`) и документацию (`/api/docs`).

Режим разработки фронтенда с hot reload (запросы `/api` проксируются на бэкенд):

```bash
python -m backend --port 8000 &
cd frontend && npm run dev              # http://localhost:5173
```

### Дополнительные модули (необязательно)

```bash
pip install -e ".[ai]"      # удаление фона нейросетью: rembg + ISNet (MIT), модель ~180 МБ скачается при первом использовании
pip install -e ".[bench]"   # vtracer (MIT) для сравнения в бенчмарке
```

Без них всё работает; кнопка «AI» в инструменте Background появляется, только если установлен `[ai]`.

## Команды

| Команда | Что делает |
|---|---|
| `make test` | все тесты: pytest (движок, экспорт, бэкенд) + vitest + typecheck |
| `make build` | сборка фронтенда в `frontend/dist` |
| `make run` | запуск сервера на :8000 |
| `make examples` | перегенерировать демо-изображения `backend/examples/*.png` |
| `python scripts/benchmark.py --compare --vtracer` | замер качества: без градиентов / с градиентами / vtracer; можно передать свои картинки |
| `python -m billing.admin ...` | операторские команды: начислить кредиты, назначить план (см. ниже) |

## Структура

```
vectorize-ai/
  frontend/              React + TypeScript + Vite + Tailwind (лендинг, редактор, аккаунт)
  backend/               FastAPI: приложение, роутеры, хранилище, SSRF-безопасная загрузка по URL, защита
  vectorization-engine/  конвейер, Vector Graph, топология, субпиксель, распознавание, правки, фон
  image-processing/      декодирование, анализ, предобработка, сегментация цветов
  geometry-engine/       примитивы, подгонка кривых, углы, фигуры, симметрия
  export-engine/         SVG, PDF, EPS, DXF, PNG, водяной знак
  auth/                  пароли (scrypt), сессии, API-ключи
  billing/               тарифы, журнал кредитов, Stripe, обработка вебхуков, CLI оператора
  api/                   публичный REST API v1, коды ошибок, генератор OpenAPI
  workers/               очередь задач, пул процессов, код задач воркера
  database/              модели SQLAlchemy, сессии
  tests/                 pytest + синтетические тестовые сцены
  scripts/               генерация демо-изображений
```

Папки с дефисом содержат обычный Python-пакет с подчёркиванием (`image-processing/image_processing`). Пути прописаны в `pyproject.toml`, поэтому работает и `pip install -e .`, и запуск из исходников.

## Конфигурация (переменные окружения)

| Переменная | По умолчанию | Назначение |
|---|---|---|
| `VZ_DATA_DIR` | `./storage` | файлы изображений, SQLite, секретный ключ |
| `VZ_DATABASE_URL` | SQLite в `VZ_DATA_DIR` | любой URL SQLAlchemy (например, Postgres) |
| `VZ_SECRET_KEY` | генерируется и сохраняется | подпись квитанций API |
| `VZ_PUBLIC_URL` | `http://localhost:8000` | адреса возврата после оплаты, сервер в OpenAPI |
| `VZ_WORKERS` | число CPU − 1 (макс. 4) | число параллельных задач векторизации |
| `VZ_WORKER_MODE` | `process` | `process` (spawn) или `thread` (для тестов) |
| `VZ_JOB_TIMEOUT` | `180` | бюджет времени на одну задачу, с |
| `VZ_ANON_RETENTION_HOURS` | `24` | срок хранения изображений анонимов |
| `VZ_USER_RETENTION_DAYS` | `30` | срок хранения изображений пользователей |
| `VZ_STRIPE_SECRET_KEY`, `VZ_STRIPE_WEBHOOK_SECRET` | — | включают онлайн-оплату |
| `VZ_STRIPE_PRICE_<PLAN>` | — | ID цен Stripe, например `VZ_STRIPE_PRICE_WEB_PRO=price_...` |
| `VZ_CORS_ORIGINS` | — | список разрешённых origin через запятую |
| `VZ_SEGMENTATION_MODEL` | классическая | `package.module:factory` для подключения своей модели |

### Оплата

Пока Stripe не настроен, кнопки подписки выключены, а `/api/billing/checkout` отвечает `503 payments_not_configured`. Успешная оплата нигде не имитируется. Подписки и кредиты меняются только после проверенного вебхука провайдера (`/api/billing/webhook/stripe`, подпись HMAC-SHA256 с проверкой времени). Для поддержки и локального тестирования есть CLI оператора, недоступный из веба:

```bash
python -m billing.admin set-plan --email you@example.com --plan web_pro
python -m billing.admin grant-credits --email you@example.com --credits 25
```

## REST API (кратко)

```bash
curl http://localhost:8000/api/v1/vectorize -u 'API_ID:API_SECRET' \
  -F image=@logo.png -F output.file_format=svg -o result.svg
```

`POST /api/v1/vectorize`, `POST /api/v1/download`, `POST /api/v1/delete`, `GET /api/v1/account`. Режимы `production` (1 кредит), `preview` (0,2), `test` / `test_preview` (бесплатно, с водяным знаком). Полное описание — `/api/docs` (Swagger UI) и `/api/openapi.json` (OpenAPI 3.0.3).

## Тесты

```bash
python -m pytest            # 102 теста: декодирование, сегментация, геометрия, конвейер, экспорт, бэкенд
cd frontend && npm test     # vitest
```

Тесты движка используют синтетические сцены с настоящим box-filter сглаживанием (`tests/synthetic.py`) и проверяют точность (векторный рендер против исходника), отсутствие щелей (каждая граница принадлежит ровно двум фигурам, покрытие = 100 %), распознавание фигур и корректность всех форматов: PDF рендерится через poppler, DXF читается ezdxf, SVG валидируется XML-парсером.
