"""JarCut 2.0 — дубляж видео.

Архитектура:
  0. Colab (свой GPU-сервер, jarcut_gpu.py) -> очистка звука: голос отдельно,
     фон отдельно (audio-separator, Roformer-модели), из голоса убираются эхо и шум
  1. ElevenLabs Scribe -> текст + тайминги слов + спикеры (по очищенному голосу)
  2. Gemini            -> перевод
  3. Colab / OmniVoice -> озвучка клоном голоса спикера
  4. ffmpeg            -> сборка: дубляж + фон оригинала (+ смех и реакции
                          оригинала в паузах между репликами)

Запуск: python server.py   (нужен Python 3.10+ и ffmpeg/ffprobe в PATH)
Открыть: http://localhost:8000
Ссылку из Colab (строка JARCUT_GPU_URL=...) вставить в .env.
.env перечитывается на лету для ссылки Colab, настроек Gemini (режим, ключ,
модель, GEMINI_RPM) и настроек озвучки OmniVoice (OMNIVOICE_*) — после их
замены перезапускать server.py не нужно.
Один раз при запуске читаются только ключ ElevenLabs и адрес/порт сервера
(JARCUT_HOST, по умолчанию 127.0.0.1 — сервер виден только с этого компьютера;
JARCUT_HOST=0.0.0.0 откроет его всей локальной сети, без пароля).
"""

import sys

if sys.version_info < (3, 10):
    raise SystemExit("JarCut нужен Python 3.10 или новее (сейчас " + sys.version.split()[0] + ")")

import asyncio
import base64
import hashlib
import json
import math
import os
import re
import shutil
import subprocess
import tempfile
import time
import uuid
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from typing import Any
from urllib.parse import parse_qs, urlsplit

import httpx
import numpy as np
from dotenv import dotenv_values, load_dotenv
from fastapi import FastAPI, File, HTTPException, Request, UploadFile
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles

ENV_FILE = Path(__file__).resolve().parent / ".env"
# Окружение ДО чтения .env — чтобы при перечитывании .env отличать системные
# значения от тех, что когда-то пришли из .env (удалённая из .env строка не
# должна продолжать действовать).
_SYSTEM_ENV = dict(os.environ)
# override=True: значения из .env главнее переменных, заданных в системе/терминале,
# иначе забытый где-то старый ключ тихо перебивает новый из .env.
load_dotenv(ENV_FILE, override=True)

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

_env_cache: dict[str, Any] = {"mtime": None, "values": {}}


def env_now(name: str, default: str = "") -> str:
    """Значение из .env прямо сейчас (файл перечитывается, если он изменился);
    если такой строки в .env нет — из системного окружения."""
    try:
        mtime = ENV_FILE.stat().st_mtime_ns
    except OSError:
        mtime = None
    if mtime != _env_cache["mtime"]:
        try:
            _env_cache["values"] = dict(dotenv_values(ENV_FILE)) if mtime is not None else {}
        except Exception:
            _env_cache["values"] = {}
        _env_cache["mtime"] = mtime
    values = _env_cache["values"]
    raw = values.get(name) if name in values else _SYSTEM_ENV.get(name)
    value = str(raw or "").strip().strip('"').strip("'").strip()
    return value or default


def mask_key(key: str) -> str:
    return f"{key[:4]}…, {len(key)} символов" if key else "пусто"


def parse_bool(value: Any, default: bool = False) -> bool:
    """bool() из JSON/формы: bool("0") и bool("false") в Python — True,
    поэтому строки разбираются явно."""
    if value is None:
        return default
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)):
        return value != 0
    text = str(value).strip().lower()
    if text in ("1", "true", "yes", "on", "да"):
        return True
    if text in ("0", "false", "no", "off", "нет", ""):
        return False
    return default


def env_float(name: str, default: float, low: float | None = None, high: float | None = None) -> float:
    try:
        value = float(env_now(name, str(default)))
    except ValueError:
        value = default
    if low is not None:
        value = max(low, value)
    if high is not None:
        value = min(high, value)
    return value


def gemini_config() -> dict[str, str]:
    """Режим, ключ и модель Gemini. Читаются из .env на КАЖДОМ запросе:
    замена ключа, модели или режима работает без перезапуска server.py.

    backend: "aistudio" (по умолчанию) = Gemini API с aistudio.google.com;
    "vertex" = Vertex AI (требует включённой оплаты в проекте Google Cloud).
    У них разные ключи. С сентября 2026 AI Studio выдаёт только ключи вида
    AQ.… — они передаются тем же заголовком x-goog-api-key.
    В режиме aistudio ключ Vertex ищется последним, чтобы оставшаяся в .env
    строка VERTEX_API_KEY не перебивала ключ AI Studio."""
    backend = env_now("GEMINI_BACKEND", "aistudio").lower()
    if backend not in ("vertex", "aistudio"):
        backend = "aistudio"
    names = (
        ("AI_STUDIO_API_KEY", "GEMINI_API_KEY", "VERTEX_API_KEY")
        if backend == "aistudio"
        else ("VERTEX_API_KEY", "GEMINI_API_KEY")
    )
    key, source = "", ""
    for name in names:
        value = env_now(name)
        if value:
            key, source = value, name
            break
    return {
        "backend": backend,
        "key": key,
        "source": source,
        "model": env_now("GEMINI_TRANSLATE_MODEL", "gemini-3.8-flash"),
        "vertex_mode": env_now("VERTEX_MODE", "express").lower(),
        "vertex_project": env_now("VERTEX_PROJECT_ID"),
        "vertex_location": env_now("VERTEX_LOCATION", "global"),
    }


ELEVENLABS_API_KEY = os.getenv("ELEVENLABS_API_KEY", "").strip()
SCRIBE_MODEL = os.getenv("ELEVENLABS_SCRIBE_MODEL", "scribe_v2").strip()

ELEVENLABS_API_BASE = "https://api.elevenlabs.io/v1"

# --- Colab GPU-сервер (ноутбук JarCut_GPU.ipynb) -----------------------------
# Ноутбук печатает одну строку вида
#   JARCUT_GPU_URL=https://xxxx.trycloudflare.com/?key=...
# Ссылка меняется при каждом перезапуске Colab. .env перечитывается на каждом
# запросе (см. gpu_endpoint), поэтому перезапускать server.py не нужно.
GPU_URL_ENV_NAME = "JARCUT_GPU_URL"

# Настройки OmniVoice — отправляются на Colab с каждой репликой и читаются из
# .env на КАЖДОМ запросе (можно менять и сравнивать на слух без перезапуска).
#
# По умолчанию — официальные значения модели (k2-fsa/OmniVoice 0.2.1):
# 32 шага и guidance 2.0. Раньше здесь стояли 64 и 4.0 — это самые крайние
# значения ползунков в их собственном демо. guidance — это сила CFG:
# log p = cond + g * (cond - uncond). При g=4 распределение становится слишком
# «острым»: голос звучит жёстче, металличнее, с преувеличенной интонацией,
# а 64 шага вдвое медленнее 32 почти без выигрыша.
def omnivoice_settings() -> dict[str, Any]:
    ref_source = env_now("OMNIVOICE_REF_SOURCE", "clean").lower()
    ref_mode = env_now("OMNIVOICE_REF_MODE", "auto").lower()
    return {
        "num_step": int(env_float("OMNIVOICE_NUM_STEP", 32, 4, 128)),
        "guidance_scale": env_float("OMNIVOICE_GUIDANCE_SCALE", 2.0, 0.0, 10.0),
        "speed": env_float("OMNIVOICE_SPEED", 1.0, 0.5, 2.0),
        "denoise": parse_bool(env_now("OMNIVOICE_DENOISE", "1"), True),
        # clean = голос после очистки (без эха и шума); raw = голос сразу после
        # отделения от музыки, без удаления эха/шума. OmniVoice обучали на
        # референсах с добавленным шумом и эхом (токен <|denoise|>), поэтому
        # raw часто клонирует тембр точнее: в нём нет артефактов шумодава.
        "ref_source": ref_source if ref_source in ("clean", "raw") else "clean",
        # auto = референс из самой реплики и соседних реплик того же спикера;
        # speaker = один лучший референс на спикера для всех реплик (голос
        # одинаковый по всему видео, но эмоция конкретной реплики не передаётся).
        "ref_mode": ref_mode if ref_mode in ("auto", "speaker") else "auto",
        # Сколько секунд голоса собирать в референс (OmniVoice советует 3–10 с).
        "ref_target": env_float("OMNIVOICE_REF_TARGET", 6.0, 3.0, 10.0),
        # Подгонка под длину: если озвученная реплика не влезает до начала
        # следующей, OmniVoice генерирует её заново сразу нужной длины
        # (параметр duration). Это звучит естественнее, чем ускорение atempo.
        "fit_duration": parse_bool(env_now("OMNIVOICE_FIT_DURATION", "1"), True),
        "fit_max_speedup": env_float("OMNIVOICE_FIT_MAX_SPEEDUP", 1.35, 1.0, 2.0),
    }


# OmniVoice понимает свои названия языков; почти все совпадают с LANGS, эти — нет.
# (Проверено по omnivoice/utils/lang_map.py: "kirghiz" -> ky, "standard arabic" -> arb;
# просто "Arabic" OmniVoice НЕ знает и молча генерирует без языка.)
OMNIVOICE_LANG_OVERRIDES = {"Kyrgyz": "Kirghiz", "Arabic": "Standard Arabic"}

# Референс для клонирования. Документация OmniVoice советует 3–10 секунд:
# длиннее — медленнее и может ухудшить клон.
REF_LINE_MIN_SECONDS = 3.0
REF_LINE_MAX_SECONDS = 10.0
REF_MAX_TOTAL_SECONDS = 10.0
# Соседние реплики для референса берутся только из этого окна вокруг реплики:
# голос в другом конце видео может звучать иначе (другая сцена, микрофон).
REF_NEIGHBOR_WINDOW_SECONDS = 120.0
# Запас по краям вырезаемого куска: Scribe ставит границы слов впритык,
# без запаса срезается первый/последний звук, и текст перестаёт совпадать
# со звуком. Запас никогда не залезает на соседнюю реплику. Лишняя тишина
# не мешает: OmniVoice сам обрезает края референса до 0.1–0.2 с.
REF_PAD_SECONDS = 0.15

# Экспорт: под репликой дубляжа фон приглушается до этой доли (0.35 ≈ −9 дБ).
DUCK_GAIN = float(os.getenv("DUCK_GAIN", "0.35"))
# Длина плавного перехода громкости (приглушение фона, выключение реакций).
FADE_SECONDS = 0.08

# Тишина по краям сгенерированной реплики: длиннее этого — обрезается до этого.
# Тишина в начале больше НЕ задерживает голос: экспорт сдвигает клип раньше
# ровно на её длину (см. plan_dub_placement).
EDGE_SILENCE_KEEP_SECONDS = max(0.05, float(os.getenv("EDGE_SILENCE_KEEP_SECONDS", "1.0")))


def vertex_model_url(config: dict[str, str]) -> str:
    """Адрес GenerateContent для выбранного режима (ключ в адрес не кладём)."""
    model = config["model"]
    if config["backend"] == "aistudio":
        return f"https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent"
    project, location = config["vertex_project"], config["vertex_location"]
    if config["vertex_mode"] == "express" or not project:
        return f"https://aiplatform.googleapis.com/v1/publishers/google/models/{model}:generateContent"
    host = "https://aiplatform.googleapis.com" if location == "global" else f"https://{location}-aiplatform.googleapis.com"
    return f"{host}/v1/projects/{project}/locations/{location}/publishers/google/models/{model}:generateContent"


def vertex_headers(config: dict[str, str]) -> dict[str, str]:
    return {"Content-Type": "application/json", "x-goog-api-key": config["key"]}


# Темп запросов к Gemini. GEMINI_RPM в .env — сколько запросов в минуту можно
# (у бесплатного ключа это несколько штук). Если Google всё же ответил 429,
# промежуток сам вырастает до 12 с (5 запросов в минуту) до перезапуска.
_gemini_pacing: dict[str, float] = {"next": 0.0, "adaptive_spacing": 0.0}
_gemini_pacing_lock = asyncio.Lock()


async def gemini_wait_turn(tag: str) -> None:
    try:
        rpm = float(env_now("GEMINI_RPM", "0"))
    except ValueError:
        rpm = 0.0
    spacing = max(60.0 / rpm if rpm > 0 else 0.0, _gemini_pacing["adaptive_spacing"])
    async with _gemini_pacing_lock:
        now = time.monotonic()
        wait = _gemini_pacing["next"] - now
        _gemini_pacing["next"] = max(now, _gemini_pacing["next"]) + spacing
    if wait > 0.5:
        print(f"{tag} пауза {wait:.0f} с, чтобы не превысить лимит запросов в минуту", flush=True)
        await asyncio.sleep(wait)


BASE = Path(__file__).resolve().parent
UPLOADS = BASE / "uploads"
EXPORTS = BASE / "exports"
for directory in (UPLOADS, EXPORTS):
    directory.mkdir(exist_ok=True)

app = FastAPI(title="JarCut 2.0")

LANGS = {
    "uz": "Uzbek", "ru": "Russian", "en": "English", "tr": "Turkish",
    "kk": "Kazakh", "ky": "Kyrgyz", "tg": "Tajik", "ar": "Arabic",
    "de": "German", "fr": "French", "es": "Spanish", "ko": "Korean", "ja": "Japanese",
}

VOICES = {
    "Kore", "Puck", "Charon", "Fenrir", "Aoede", "Leda", "Orus", "Zephyr",
    "Callirrhoe", "Autonoe", "Enceladus", "Iapetus", "Umbriel", "Algieba",
    "Despina", "Erinome", "Algenib", "Rasalgethi", "Laomedeia", "Achernar",
    "Alnilam", "Schedar", "Gacrux", "Pulcherrima", "Achird",
}
VOICE_POOL = sorted(VOICES)

MIME_TYPES = {
    ".mp4": "video/mp4", ".webm": "video/webm", ".mov": "video/quicktime",
    ".mkv": "video/x-matroska", ".avi": "video/x-msvideo",
    ".mp3": "audio/mpeg", ".wav": "audio/wav", ".m4a": "audio/mp4",
}


@app.get("/")
async def root() -> FileResponse:
    return FileResponse(str(BASE / "index.html"))


@app.get("/api/diagnostics")
async def diagnostics() -> dict[str, Any]:
    gemini = gemini_config()
    gpu_set = gpu_endpoint() is not None
    return {
        "ok": bool(gemini["key"]) and bool(ELEVENLABS_API_KEY) and gpu_set,
        "geminiKeySet": bool(gemini["key"]),
        "geminiBackend": gemini["backend"],
        "elevenlabsKeySet": bool(ELEVENLABS_API_KEY),
        "gpuUrlSet": gpu_set,
        "translateModel": gemini["model"],
        "scribeModel": SCRIBE_MODEL,
        "omnivoice": omnivoice_settings(),
    }


_SAFE_SUFFIX = re.compile(r"^\.[a-z0-9]{1,8}$")


def _save_upload(source: Any, target: Path) -> None:
    with open(target, "wb") as handle:
        shutil.copyfileobj(source, handle, length=4 * 1024 * 1024)


@app.post("/api/upload")
async def upload(file: UploadFile = File(...)) -> dict[str, Any]:
    suffix = Path(file.filename or "video.mp4").suffix.lower() or ".mp4"
    if not _SAFE_SUFFIX.match(suffix):
        suffix = ".mp4"
    name = f"{uuid.uuid4().hex[:12]}{suffix}"
    # Потоком на диск: раньше file.read() держал всё видео в памяти целиком.
    await asyncio.to_thread(_save_upload, file.file, UPLOADS / name)
    return {"ok": True, "filename": name, "url": f"/uploads/{name}"}


# ---------------------------------------------------------------------------
# Step 1: ElevenLabs Scribe — точные тайминги
# ---------------------------------------------------------------------------


def extract_audio(source: Path, target: Path) -> bool:
    command = [
        "ffmpeg", "-y", "-i", str(source), "-vn", "-ac", "1", "-ar", "16000",
        "-codec:a", "libmp3lame", "-b:a", "64k", str(target),
    ]
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=300)
        return result.returncode == 0 and target.exists() and target.stat().st_size > 0
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return False




def extract_segment_wav(source: Path, start: float, end: float, target: Path, normalize: bool = True) -> bool:
    """Extract one segment's audio only (no video) as a WAV file — used to
    build the per-speaker reference clip for OmniVoice voice cloning.

    normalize=True applies EBU R128 loudness normalization (ffmpeg's
    loudnorm filter) to a fixed target level. This is specifically to fix
    one speaker's reference clip being naturally quieter than another's
    (e.g. one person recorded further from the mic) — cloning from an
    unbalanced reference tends to carry that same volume imbalance into
    the generated output for that speaker. loudnorm's single-pass mode
    only adjusts the overall/perceived loudness target; it does NOT
    compress the internal dynamic range of the clip, so a genuine shout
    within the reference clip still comes out louder than the speaker's
    own quieter moments — this only equalizes the baseline between
    different speakers, not within one speaker's natural range.
    """
    duration = max(0.1, end - start)
    audio_filter = "loudnorm=I=-18:TP=-1.5:LRA=11" if normalize else None
    command = [
        "ffmpeg", "-y", "-ss", f"{start:.3f}", "-i", str(source), "-t", f"{duration:.3f}",
        "-vn", "-ac", "1", "-ar", "24000",
    ]
    if audio_filter:
        command.extend(["-af", audio_filter])
    command.extend(["-c:a", "pcm_s16le", str(target)])
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=30)
        return result.returncode == 0 and target.exists() and target.stat().st_size > 44
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return False




def concat_audio_clips(pieces: list[Path], final_path: Path, out_dir: Path, tag: str) -> Path | None:
    """Concatenate several short WAV clips (with a brief silence gap between
    each) into one file — shared helper used both for a speaker's general
    reference clip and for stitching neighboring same-speaker lines when a
    single line is too short to clone from on its own."""
    if len(pieces) == 1:
        return pieces[0]

    concat_list_path = out_dir / f"concat_{tag}.txt"
    silence_path = out_dir / f"silence_{tag}.wav"
    subprocess.run(
        ["ffmpeg", "-y", "-f", "lavfi", "-i", "anullsrc=r=24000:cl=mono", "-t", "0.2", str(silence_path)],
        capture_output=True, timeout=15,
    )
    with open(concat_list_path, "w") as f:
        for i, piece in enumerate(pieces):
            f.write(f"file '{piece.resolve()}'\n")
            if i < len(pieces) - 1:
                f.write(f"file '{silence_path.resolve()}'\n")

    result = subprocess.run(
        ["ffmpeg", "-y", "-f", "concat", "-safe", "0", "-i", str(concat_list_path), "-c", "copy", str(final_path)],
        capture_output=True, text=True, timeout=30,
    )
    if result.returncode == 0 and final_path.exists() and final_path.stat().st_size > 44:
        return final_path
    return None




async def transcribe_with_scribe(audio_path: Path) -> dict[str, Any]:
    """Call ElevenLabs Scribe for word-level timestamps + speaker diarization."""
    if not ELEVENLABS_API_KEY:
        raise HTTPException(500, {"code": "NO_ELEVENLABS_KEY", "message": "ELEVENLABS_API_KEY не задан в .env"})

    url = f"{ELEVENLABS_API_BASE}/speech-to-text"
    headers = {"xi-api-key": ELEVENLABS_API_KEY}

    with open(audio_path, "rb") as audio_file:
        files = {"file": (audio_path.name, audio_file, "audio/mpeg")}
        data = {
            "model_id": SCRIBE_MODEL,
            "diarize": "true",
            "timestamps_granularity": "word",
            "tag_audio_events": "false",
        }
        try:
            async with httpx.AsyncClient(timeout=300) as client:
                response = await client.post(url, headers=headers, data=data, files=files)
        except httpx.RequestError as exc:
            raise HTTPException(502, {"code": "SCRIBE_UNREACHABLE", "message": f"Не удалось связаться с ElevenLabs: {exc}"}) from exc

    if response.status_code != 200:
        raise HTTPException(response.status_code, {"code": "SCRIBE_ERROR", "message": response.text[:500]})

    return response.json()


# Characters that can trail a sentence-ending mark without changing it
# (a closing quote or bracket right after the period: `said "no."`).
_SENTENCE_TRAILERS = "\"'”’»)]}」』）】"
# Tokens made only of these are punctuation, not words.
_PUNCTUATION_ONLY = set(".,;:!?…-–—\"'“”‘’«»()[]{}。、，！？；：「」『』（）【】؟،؛¿¡")
# Sentence-ending marks: Latin/Cyrillic, full-width CJK, Arabic question mark.
_SENTENCE_END_MARKS = ".!?。！？؟"
# Abbreviations whose trailing period does NOT end a sentence ("Dr. Smith").
_NON_FINAL_ABBREVIATIONS = {"mr", "mrs", "ms", "dr", "st", "vs", "jr", "sr", "prof", "inc", "ltd"}


def _no_space_script(char: str) -> bool:
    """Scripts written WITHOUT spaces between words: Chinese, Japanese, Thai,
    Lao, Khmer, Myanmar. (Korean uses spaces, so Hangul is not here.)"""
    code = ord(char)
    return (
        0x3040 <= code <= 0x30FF      # Hiragana, Katakana
        or 0x3400 <= code <= 0x9FFF   # CJK ideographs (+ Ext A)
        or 0xF900 <= code <= 0xFAFF   # CJK compatibility ideographs
        or 0x3000 <= code <= 0x303F   # CJK punctuation (。、「」)
        or 0xFF00 <= code <= 0xFF65   # full-width forms (！？，)
        or 0x0E00 <= code <= 0x0EFF   # Thai, Lao
        or 0x1000 <= code <= 0x109F   # Myanmar
        or 0x1780 <= code <= 0x17FF   # Khmer
        or code >= 0x20000            # CJK extension planes
    )


def join_words(words: list[str]) -> str:
    """Join word tokens back into text. Spaces go between words, except where
    both sides are in a no-space script ("今日" + "は" -> "今日は", not "今日 は")."""
    text = ""
    for word in words:
        if text and not (_no_space_script(text[-1]) and _no_space_script(word[0])):
            text += " "
        text += word
    return text


def ends_sentence(token_text: str) -> bool:
    """True if this word token closes a sentence (ends in . ! or ?).

    Deliberately conservative — a wrong "yes" cuts a sentence in two, which
    is exactly the bug this exists to prevent, so ambiguous cases say no:
      - an ellipsis ("wait...") is usually a trailing thought, not an end;
      - "Dr." / "Mr." style abbreviations, dotted acronyms ("U.S."), and
        bare numbers ("1." list numbering, "3." in "3.5") are not ends.
    A missed boundary only merges two sentences into one segment, which is
    harmless; a false boundary breaks a sentence, which is not.
    """
    core = token_text.rstrip(_SENTENCE_TRAILERS)
    if not core or core[-1] not in _SENTENCE_END_MARKS:
        return False
    if core.endswith("...") or core.endswith("…"):
        return False
    if core[-1] == ".":
        stem = core.rstrip(".")
        if stem.lower() in _NON_FINAL_ABBREVIATIONS or stem.isdigit() or "." in stem:
            return False
    return True


def group_words_into_segments(scribe_result: dict[str, Any], verbose: bool = True) -> list[dict[str, Any]]:
    """Turn Scribe's word-level output into dubbing segments — one per
    sentence, following the speaker's own punctuation.

    A new segment starts when:
      1. the speaker changes; or
      2. the previous word ended a sentence (. ! ?) — so every segment is a
         whole sentence and the dub re-syncs to the video at each sentence
         start instead of drifting; or
      3. there is a real pause. Mid-sentence, that means MID_SENTENCE_GAP
         (a long stop, not a breath); if Scribe returned no usable
         punctuation at all, the old MAX_GAP rule applies instead.

    There is no cap on segment length: a sentence runs as long as the
    speaker's real speech does, so a sentence is never cut before its end.
    What used to give one 90-second segment was a narrator reading without
    a 0.9s pause — splitting on sentence ends fixes that properly, where a
    timer cap (the earlier 12s/20s attempts) cut sentences in half.
    """
    MAX_GAP_SECONDS = 0.9          # pause that splits when there is no punctuation to rely on
    MID_SENTENCE_GAP_SECONDS = 2.5  # pause that splits INSIDE a sentence when punctuation is reliable

    words = scribe_result.get("words") or []
    # Some Scribe responses nest words differently; normalize defensively.
    if not words and isinstance(scribe_result.get("segments"), list):
        for seg in scribe_result["segments"]:
            words.extend(seg.get("words") or [])

    # Pass 1: clean word tokens. A punctuation-only token (some outputs emit
    # "." as its own item) is glued onto the word before it, so both output
    # shapes — punctuation attached to words, or separate — end up the same.
    tokens: list[dict[str, Any]] = []
    for word in words:
        text = str(word.get("text", "")).strip()
        if not text:
            continue
        if all(ch in _PUNCTUATION_ONLY for ch in text):
            if tokens:
                tokens[-1]["text"] += text
            continue
        if word.get("type", "word") != "word":
            continue  # spacing / audio events
        start = float(word.get("start", 0))
        tokens.append({
            "text": text,
            "start": start,
            "end": float(word.get("end", start)),
            "speaker": str(word.get("speaker_id") or word.get("speaker") or "speaker_1"),
        })

    # Is punctuation present enough to trust? Natural speech has a sentence
    # end every ~10-20 words; if there's fewer than one per 60, Scribe gave
    # us essentially none, and splitting on it would produce giant segments.
    sentence_ends = sum(1 for token in tokens if ends_sentence(token["text"]))
    punctuation_reliable = sentence_ends >= max(1, len(tokens) // 60)

    # Pass 2: group.
    segments: list[dict[str, Any]] = []
    current: dict[str, Any] | None = None
    for token in tokens:
        if current is None:
            needs_new = True
        elif current["speaker_id"] != token["speaker"]:
            needs_new = True
        elif punctuation_reliable and current["closed"]:
            needs_new = True
        else:
            gap_limit = MID_SENTENCE_GAP_SECONDS if punctuation_reliable else MAX_GAP_SECONDS
            needs_new = (token["start"] - current["end"]) > gap_limit

        if needs_new:
            if current is not None:
                segments.append(current)
            current = {
                "speaker_id": token["speaker"],
                "start": token["start"],
                "end": token["end"],
                "words": [token["text"]],
                "closed": ends_sentence(token["text"]),
            }
        else:
            current["end"] = token["end"]
            current["words"].append(token["text"])
            current["closed"] = ends_sentence(token["text"])

    if current is not None:
        segments.append(current)

    for segment in segments:
        segment["original"] = join_words(segment.pop("words"))
        segment.pop("closed", None)

    if segments and verbose:
        longest = max(seg["end"] - seg["start"] for seg in segments)
        mode = "по предложениям" if punctuation_reliable else "ТОЛЬКО по паузам (Scribe не вернул знаков препинания)"
        print(f"[segments] {len(tokens)} слов, {sentence_ends} концов предложений -> {len(segments)} реплик, "
              f"режим: {mode}, самая длинная {longest:.1f}с", flush=True)

    return segments


# ---------------------------------------------------------------------------
# Step 2: Gemini — только перевод
# ---------------------------------------------------------------------------


MASCULINE_VOICES = ["Charon", "Orus", "Fenrir", "Iapetus", "Algenib", "Rasalgethi", "Enceladus"]
FEMININE_VOICES = ["Kore", "Aoede", "Leda", "Autonoe", "Callirrhoe", "Despina", "Erinome"]


@app.get("/api/voices")
async def list_voices() -> dict[str, Any]:
    return {
        "masculine": MASCULINE_VOICES,
        "feminine": FEMININE_VOICES,
        "all": VOICE_POOL,
    }


def letter_count(text: str) -> int:
    """Count Unicode letters only, ignoring spaces, punctuation, and digits."""
    return sum(character.isalpha() for character in text)


# Сколько «стоит» символ в произношении, относительно одной латинской буквы.
# Это ровно та же таблица, по которой OmniVoice (utils/duration.py,
# RuleDurationEstimator) сам решает, сколько секунд будет длиться реплика:
# длительность = вес(текст) / (вес(текст референса) / длительность референса).
# Поэтому сравнение «вес перевода / вес оригинала» прямо предсказывает, во
# сколько раз дубляж будет длиннее оригинала, — для любой пары письменностей.
# Счёт по буквам так не умел: кандзи/хангыль — это слог (2–3 латинские буквы),
# и японский/корейский перевод казался «вдвое короче» оригинала.
_SCRIPT_WEIGHT_RANGES = (
    (0x02AF, 1.0), (0x03FF, 1.0), (0x052F, 1.0), (0x058F, 1.0),   # latin, greek, cyrillic, armenian
    (0x05FF, 1.5), (0x08FF, 1.5),                                  # hebrew, arabic
    (0x0DFF, 1.8),                                                 # indic
    (0x0EFF, 1.5),                                                 # thai, lao
    (0x0FFF, 1.8), (0x109F, 1.8),                                  # tibetan, myanmar
    (0x10FF, 1.0),                                                 # georgian
    (0x11FF, 2.5),                                                 # hangul jamo
    (0x139F, 3.0),                                                 # ethiopic
    (0x17FF, 1.8),                                                 # khmer
    (0x1EFF, 1.0),                                                 # latin extended (vietnamese)
    (0x30FF, 2.2),                                                 # hiragana, katakana
    (0x312F, 3.0), (0x318F, 2.5),                                  # bopomofo, hangul compat jamo
    (0x9FFF, 3.0),                                                 # CJK ideographs
    (0xA4CF, 3.0),                                                 # yi
    (0xD7AF, 2.5),                                                 # hangul syllables
    (0xFAFF, 3.0),                                                 # CJK compatibility
    (0xFDFF, 1.5), (0xFEFF, 1.5),                                  # arabic presentation forms
)


def _char_weight(char: str) -> float:
    import unicodedata

    if char == " ":
        return 0.2
    category = unicodedata.category(char)
    if category.startswith("M") or char == "ـ":
        return 0.0          # diacritics, tatweel
    if category[0] in "PS":
        return 0.5          # punctuation: a short pause
    if category.startswith("Z"):
        return 0.2
    if category.startswith("N"):
        return 3.5          # a digit is read as a whole word
    code = ord(char)
    for end, weight in _SCRIPT_WEIGHT_RANGES:
        if code <= end:
            return weight
    return 3.0 if code > 0x20000 else 1.0


def speech_weight(text: str) -> float:
    """Примерная «длина произношения» текста в латинских буквах."""
    return sum(_char_weight(char) for char in re.sub(r"\s+", " ", text.strip()))


def letters_for_weight(text: str, target_weight: float) -> int:
    """Сколько букв этого же текста (в его письменности) соответствует
    target_weight — так Gemini получает понятный ему лимит в буквах."""
    letters = letter_count(text)
    weight = speech_weight(text)
    if letters == 0 or weight <= 0:
        return max(1, int(round(target_weight)))
    return max(1, int(letters * target_weight / weight))


# HTTP statuses that mean "Google had a problem, try again", not "your request
# is wrong" — see the retry policy inside call_gemini_json.
_TRANSIENT_GEMINI_STATUSES = {500, 502, 503, 504}


async def call_gemini_json(
    prompt: str,
    timeout: int = 180,
    media_parts: list[dict[str, Any]] | None = None,
    label: str = "",
    max_attempts: int | None = None,
) -> dict[str, Any]:
    """Send one prompt to Gemini and parse a JSON object from its reply.

    media_parts (optional): extra inlineData parts (e.g. video) placed
    BEFORE the text part, so Gemini can ground its answer in what it
    actually sees/hears rather than the text prompt alone.

    label: short name of the calling step ("review 3/7"), shown in the log
    lines so a failure says WHICH request it was. Before this, a timeout
    line looked identical for the translation and for every review pass.
    max_attempts: overrides the default attempt count (see below).
    """
    parts: list[dict[str, Any]] = list(media_parts or [])
    parts.append({"text": prompt})
    payload = {
        "contents": [{"role": "user", "parts": parts}],
        "generationConfig": {"temperature": 0.2, "responseMimeType": "application/json"},
    }
    # Retry policy — two kinds of failure, handled differently:
    #
    # 1) No answer at all (timeout / connection error). Retried up to
    #    max_attempts times. Requests carrying audio use a long timeout (up
    #    to 30 minutes), so they default to 2 attempts — 3 would mean up to
    #    90 minutes sitting in front of a stuck UI. Plain text requests are
    #    cheap to retry and keep 3.
    #
    # 2) Google ANSWERED with a transient server-side status:
    #      429 rate limit (the limit is time-window based, so wait 30s/60s);
    #      500/502/503/504 internal error / overloaded / timed out on their
    #      side — Google's own guidance for these is "retry after a short
    #      wait". These come back fast, so retrying is cheap, and it matters:
    #      previously a single 500 failed the whole request and discarded
    #      every chunk already translated (minutes of work, and tokens paid
    #      for). Up to 3 attempts, waiting 10s/20s.
    # Other statuses (400/401/403/404 ...) are NOT retried: repeating the
    # same request can't fix a bad key, a billing block or a bad request.
    max_attempts = max_attempts or (2 if media_parts else 3)
    status_attempts = max(max_attempts, 3)
    tag = f"[gemini:{label}]" if label else "[gemini]"
    config = gemini_config()  # свежие ключ/модель/режим из .env
    last_exc: httpx.RequestError | None = None
    response = None
    attempts_made = 0
    for attempt in range(1, status_attempts + 1):
        attempts_made = attempt
        await gemini_wait_turn(tag)
        attempt_started = time.monotonic()
        try:
            async with httpx.AsyncClient(timeout=timeout) as client:
                response = await client.post(vertex_model_url(config), headers=vertex_headers(config), json=payload)
            last_exc = None
        except httpx.RequestError as exc:
            last_exc = exc
            elapsed = time.monotonic() - attempt_started
            if attempt < max_attempts:
                print(f"{tag} attempt {attempt}/{max_attempts} failed after {elapsed:.1f}s (timeout was {timeout}s), retrying: {exc!r}", flush=True)
                await asyncio.sleep(2.0 * attempt)
                continue
            print(f"{tag} attempt {attempt}/{max_attempts} (final) failed after {elapsed:.1f}s (timeout was {timeout}s): {exc!r}", flush=True)
            break

        status = response.status_code
        elapsed = time.monotonic() - attempt_started
        if status == 429:
            # Дальше идём не чаще 5 запросов в минуту — до перезапуска server.py.
            _gemini_pacing["adaptive_spacing"] = max(_gemini_pacing["adaptive_spacing"], 12.0)
        if status == 429 and attempt < status_attempts:
            wait_seconds = 30.0 * attempt
            print(f"{tag} attempt {attempt}/{status_attempts} hit rate limit (429) after {elapsed:.1f}s, "
                  f"waiting {wait_seconds:.0f}s before retry", flush=True)
            await asyncio.sleep(wait_seconds)
            continue
        if status in _TRANSIENT_GEMINI_STATUSES and attempt < status_attempts:
            wait_seconds = 10.0 * attempt
            snippet = " ".join(response.text.split())[:160]
            print(f"{tag} attempt {attempt}/{status_attempts} got HTTP {status} from Google after {elapsed:.1f}s "
                  f"({snippet}) — waiting {wait_seconds:.0f}s before retry", flush=True)
            await asyncio.sleep(wait_seconds)
            continue
        break

    if last_exc is not None:
        detail = str(last_exc) or f"{type(last_exc).__name__} (пустое сообщение об ошибке)"
        raise HTTPException(502, {"code": "GEMINI_UNREACHABLE", "message": f"Не удалось получить ответ от Gemini после {attempts_made} попыток: {detail}"}) from last_exc

    if response.status_code != 200:
        message = response.text[:500]
        # Always leave the real reason in the terminal too, so a pasted log
        # is self-contained (the browser only shows the tail of long errors).
        print(f"{tag} HTTP {response.status_code} after {attempts_made} attempt(s): {' '.join(response.text.split())[:300]}", flush=True)
        if response.status_code in (400, 401, 403) and (
            "API key not valid" in response.text or "ACCESS_TOKEN_TYPE_UNSUPPORTED" in response.text
        ):
            where = "AI Studio" if config["backend"] == "aistudio" else "Vertex AI"
            hint = (
                "ключ со страницы aistudio.google.com → Get API key (новые ключи начинаются с AQ., это нормально), "
                "в .env строкой AI_STUDIO_API_KEY=... Если ключ точно оттуда — проверь его: python check_gemini.py"
                if config["backend"] == "aistudio"
                else "нужен ключ Vertex AI, либо переключись на AI Studio: GEMINI_BACKEND=aistudio + AI_STUDIO_API_KEY=..."
            )
            message = (
                f"Google не принял ключ для {where}. Сейчас ключ взят из {config['source'] or '(нигде)'} "
                f"({mask_key(config['key'])}) — {hint}. Новый ключ в .env подхватится сам, без перезапуска.\n" + message
            )
            print(f"{tag} {message.splitlines()[0]}", flush=True)
        elif response.status_code == 403 and "dunning" in response.text.lower():
            # Not a script problem: Google's billing system is refusing this
            # whole project. Say so plainly instead of leaving a raw blob.
            message = (
                "Google отклонил запрос из-за биллинга проекта (не из-за скрипта). "
                "Проверь оплату этого проекта в Google Cloud, либо переключись на ключ AI Studio: "
                "GEMINI_BACKEND=aistudio в .env.\n" + message
            )
        elif response.status_code in _TRANSIENT_GEMINI_STATUSES:
            message = (
                f"Сбой на стороне Google (HTTP {response.status_code}), запрос повторён {attempts_made} раз(а) — не помогло. "
                "Это не ошибка скрипта; обычно проходит через несколько минут.\n" + message
            )
        raise HTTPException(response.status_code, {"code": "GEMINI_ERROR", "message": message})

    # Parse defensively and, on failure, say WHY in the terminal. A bare
    # "500" with no log line gave no way to tell the likely causes apart:
    #  - finishReason MAX_TOKENS: the JSON was cut off mid-way (a long
    #    batch of Uzbek lines is token-heavy, so 100+ lines can run into
    #    the output limit);
    #  - finishReason SAFETY / PROHIBITED_CONTENT / RECITATION, or no
    #    candidates at all: Gemini blocked or returned nothing;
    #  - the first part not being the answer text (some models emit extra
    #    parts), which reading only parts[0] would miss.
    try:
        body = response.json()
        candidates = body.get("candidates") or []
        candidate = candidates[0] if candidates else {}
        finish_reason = candidate.get("finishReason", "UNKNOWN")
        block_reason = (body.get("promptFeedback") or {}).get("blockReason")
        parts = (candidate.get("content") or {}).get("parts") or []
        # Join every non-"thought" text part instead of trusting parts[0].
        text = "".join(
            str(part.get("text", "")) for part in parts
            if isinstance(part, dict) and not part.get("thought")
        ).strip()
        if not text:
            raise ValueError(
                f"пустой ответ (finishReason={finish_reason}"
                f"{', blockReason=' + str(block_reason) if block_reason else ''}, candidates={len(candidates)})"
            )
        if text.startswith("```"):
            text = text.split("\n", 1)[1].rsplit("```", 1)[0].strip()
        try:
            return json.loads(text)
        except json.JSONDecodeError as exc:
            raise ValueError(
                f"JSON не разобрался: {exc} (finishReason={finish_reason}, "
                f"длина ответа {len(text)} символов, конец: ...{text[-80:]!r})"
            ) from exc
    except Exception as exc:
        print(f"{tag} BAD RESPONSE: {exc}", flush=True)
        raise HTTPException(500, {"code": "BAD_GEMINI_JSON", "message": f"Не удалось разобрать ответ Gemini: {exc}"}) from exc


def plan_translation_chunks(
    source_video: Path,
    segments: list[dict[str, Any]],
    max_chunk_bytes: int = 14 * 1024 * 1024,
    max_chunk_duration_seconds: float = 20 * 60,
) -> list[tuple[int, int, float, float]]:
    """Group segments into chunks small enough to fit Gemini's inline-data
    limit AND short enough to avoid the latency Google's own docs warn
    about for longer clips, splitting ONLY between segments (never
    mid-line — i.e. always in a gap of silence between two lines, never
    while someone is mid-sentence).

    Returns a list of (first_segment_index, last_segment_index_exclusive,
    video_start_seconds, video_end_seconds) — one entry per chunk.

    Why split between segments rather than at fixed time intervals: cutting
    mid-sentence hands Gemini half a line with no way to know what was said
    before/after the cut, which is exactly the context-blindness the video
    context was added to fix. Cut points are placed at the midpoint of the
    gap between one segment ending and the next beginning, so every line
    stays whole and the cut always lands during silence.

    Two independent budgets cap each chunk, and the tighter one wins:
      - max_chunk_bytes: Vertex AI's actual documented inline-data ceiling
        is 20MB for the TOTAL request payload (not ~95-100MB as earlier
        assumed), and base64 encoding inflates raw bytes by ~33%, so 14MB
        of raw audio becomes ~19MB encoded, leaving headroom for the text
        portion of the same request.
      - max_chunk_duration_seconds: this limit originally existed because
        Google's video-understanding docs warn that STATIC video
        processing (extracting frames at 1 FPS across the whole clip
        before generating any response) causes real latency/timeouts past
        ~5 minutes — confirmed directly: a 24-minute video timed out
        repeatedly even once comfortably under the byte budget, because
        the bottleneck was 1440 frames processed serially, not payload
        size. Now that translation sends AUDIO ONLY (video frames dropped
        entirely — see extract_audio_for_gemini, done specifically to cut
        per-token cost), that frame-processing bottleneck doesn't apply;
        this duration cap is kept generous (20 minutes) purely as a safety
        net against runaway latency on unusually long single lines rather
        than a real observed constraint, so max_chunk_bytes is the budget
        that actually decides chunk boundaries in practice.
    """
    if not segments:
        return []

    total_bytes = source_video.stat().st_size
    total_duration = probe_duration(source_video)
    if total_duration <= 0 or total_bytes <= 0:
        # Can't estimate — fall back to one chunk covering everything and
        # let the caller's size check decide whether to send video at all.
        return [(0, len(segments), 0.0, 0.0)]

    bytes_per_second = total_bytes / total_duration
    # Real video bitrate isn't uniform — a busy/high-motion stretch encodes
    # denser than a static one, so a chunk estimated purely from the whole
    # video's AVERAGE bytes-per-second can land meaningfully over budget if
    # it happens to cover a denser-than-average section (confirmed in
    # testing: a chunk planned for 14MB came out at 16.4MB). Estimating
    # against 70% of the nominal budget leaves headroom for that variance
    # without needing to actually cut-and-measure every candidate chunk.
    SAFETY_FACTOR = 0.7
    max_seconds_by_size = (max_chunk_bytes * SAFETY_FACTOR) / bytes_per_second
    max_chunk_seconds = min(max_seconds_by_size, max_chunk_duration_seconds)

    chunks: list[tuple[int, int, float, float]] = []
    chunk_start_index = 0
    chunk_start_time = 0.0

    for index, segment in enumerate(segments):
        segment_end = float(segment.get("end", 0))
        # Would adding this segment push the chunk past either budget
        # (size or duration — whichever is tighter)?
        if segment_end - chunk_start_time > max_chunk_seconds and index > chunk_start_index:
            # Cut in the gap between the previous segment and this one, so
            # neither line is split — this lands the cut during a silent
            # pause, never mid-sentence. Midpoint of the gap keeps a little
            # margin on both sides.
            previous_end = float(segments[index - 1].get("end", 0))
            cut_point = (previous_end + float(segment.get("start", previous_end))) / 2
            chunks.append((chunk_start_index, index, chunk_start_time, cut_point))
            chunk_start_index = index
            chunk_start_time = cut_point

    # Final chunk runs to the end of the video.
    chunks.append((chunk_start_index, len(segments), chunk_start_time, total_duration))
    return chunks




def cut_audio_chunk(source: Path, start: float, end: float, target: Path) -> bool:
    """Cut one time range out of an audio-only file (see
    extract_audio_for_gemini) for use as translation context — same
    re-encode-not-copy rationale as cut_video_chunk, but with audio-only
    codec flags since there's no video stream to carry."""
    duration = max(0.1, end - start)
    command = [
        "ffmpeg", "-y", "-ss", f"{start:.3f}", "-i", str(source), "-t", f"{duration:.3f}",
        "-c:a", "aac", "-b:a", "48k",
        str(target),
    ]
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=300)
        return result.returncode == 0 and target.exists() and target.stat().st_size > 0
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return False


def extract_audio_for_gemini(source: Path, target: Path) -> bool:
    """Extract JUST the audio track for sending to Gemini as translation
    context, instead of the full video.

    Why audio-only instead of video: Gemini bills video frames as tokens
    at roughly 1 fps by default, and for a 24-minute clip that alone came
    to hundreds of thousands of tokens per translation request — around
    $1+ per video on gemini-3.1-pro-preview, confirmed by direct
    calculation against Google's own published per-token rates. Audio
    tokens are billed separately and far more cheaply (~25 tokens/second,
    vs. ~300 tokens per video frame), so dropping video frames while
    keeping the audio cuts the cost by roughly 75-90% for a video this
    length. The trade-off is real: tone of voice, volume, pacing, and
    pauses are still present in audio (sarcasm delivered flatly, a raised
    voice, a hesitant pause) — what's lost is anything ONLY visible, like
    facial expression, who's looking at whom, or body language with no
    vocal cue. For a dubbing translator whose main job is getting the
    WORDS and their delivery right, audio alone still meaningfully beats
    text-only (which has neither).

    This also incidentally helps the long-video timeout/chunking problem
    from earlier: a compressed audio track is a small fraction of even a
    compressed video's size, so chunking (see plan_translation_chunks) is
    far less likely to be needed at all for a typical video.
    """
    command = [
        "ffmpeg", "-y", "-i", str(source),
        "-vn", "-ac", "1", "-ar", "16000",
        "-c:a", "aac", "-b:a", "48k",
        str(target),
    ]
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=300)
        return result.returncode == 0 and target.exists() and target.stat().st_size > 0
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return False


async def translate_segments_pass(
    segments: list[dict[str, Any]], target_language: str, language_code: str, source_video: Path | None = None
) -> None:
    """Accurate, natural translation via Gemini, with full dialogue context
    so tense, pronouns, and who's-speaking-to-whom stay correct across the
    conversation. The prompt is deliberately strict: it forbids paraphrase
    drift, requires the model to preserve exact meaning per line, and asks
    for explicit self-verification before answering — the same class of
    fix that stopped the "loses meaning" complaints in practice.

    When source_video is given, its AUDIO track (not the video frames —
    see extract_audio_for_gemini, done for cost) is sent alongside the
    text, so the translator hears tone, sarcasm, hesitation and each
    speaker's voice (used for grammatical gender, rule 9) instead of
    translating bare words.

    Long audio tracks can still exceed Gemini's inline-data ceiling for
    very long videos, so the audio is extracted ONCE up front (see
    extract_audio_for_gemini) and chunking decisions are made against that
    extracted file's size. Chunks (when still needed) are cut from the
    already-small audio file rather than the original video, which is
    faster and doesn't re-run extraction per chunk. Chunk boundaries fall
    between lines, never inside one, and each request still carries that
    chunk's full dialogue so within-chunk context is intact. Results are
    merged back by original segment index.
    """
    if not segments:
        return

    video_duration = await asyncio.to_thread(probe_duration, source_video) if source_video is not None else 0.0
    with tempfile.TemporaryDirectory(prefix="jarcut2_chunks_") as chunk_dir:
        audio_for_gemini: Path | None = None
        if source_video is not None and source_video.exists():
            candidate = Path(chunk_dir) / "audio_source.aac"
            # ffmpeg — в отдельном потоке, чтобы сервер не замирал на время извлечения.
            if await asyncio.to_thread(extract_audio_for_gemini, source_video, candidate):
                original_mb = source_video.stat().st_size / 1024 / 1024
                audio_mb = candidate.stat().st_size / 1024 / 1024
                print(f"[translate] Extracted audio for Gemini (video dropped for cost): {original_mb:.1f}MB video -> {audio_mb:.1f}MB audio", flush=True)
                audio_for_gemini = candidate
            else:
                print("[translate] Audio extraction failed, translating text-only", flush=True)

        chunks: list[tuple[int, int, float, float]] = [(0, len(segments), 0.0, 0.0)]
        if audio_for_gemini is not None:
            chunks = await asyncio.to_thread(plan_translation_chunks, audio_for_gemini, segments)
            if len(chunks) > 1:
                print(f"[translate] Still too long after extraction — splitting into {len(chunks)} chunks", flush=True)

        for chunk_number, (start_index, end_index, chunk_start, chunk_end) in enumerate(chunks, start=1):
            chunk_segments = segments[start_index:end_index]
            if not chunk_segments:
                continue

            chunk_audio: Path | None = None
            if audio_for_gemini is not None:
                if len(chunks) == 1:
                    chunk_audio = audio_for_gemini
                else:
                    candidate = Path(chunk_dir) / f"chunk_{chunk_number}.aac"
                    if await asyncio.to_thread(cut_audio_chunk, audio_for_gemini, chunk_start, chunk_end, candidate):
                        chunk_audio = candidate
                    else:
                        print(f"[translate] Failed to cut chunk {chunk_number}, translating it text-only", flush=True)

            # Space out requests to Vertex AI when there are several chunks
            # — sending audio-context requests back-to-back with no pause
            # was observed hitting Google's own per-minute rate limit (HTTP
            # 429 "RESOURCE_EXHAUSTED"), not because our own code was doing
            # anything wrong, but because Google throttles bursts of large
            # requests. Skipped before the very first chunk — nothing to
            # space out yet.
            if chunk_number > 1:
                await asyncio.sleep(15)

            # Таймаут считается от длины ЭТОГО куска (раньше — от всего видео,
            # и каждый кусок длинного видео получал максимальные 30 минут).
            chunk_length = chunk_end - chunk_start if len(chunks) > 1 and chunk_end > chunk_start else video_duration
            await _translate_one_chunk(
                chunk_segments, target_language, language_code, chunk_audio,
                chunk_label=f"{chunk_number}/{len(chunks)}" if len(chunks) > 1 else "",
                video_duration_hint=chunk_length,
            )


# Smallest batch the retry-by-splitting logic will still divide (a batch
# must be at least twice this to be split into two usable halves). Shared
# by _translate_one_chunk and the missing-lines check in
# _translate_one_chunk_attempt so the two always agree on what is splittable.
MIN_SPLIT_SIZE = 8


async def _translate_one_chunk(
    segments: list[dict[str, Any]],
    target_language: str,
    language_code: str,
    source_video: Path | None,
    chunk_label: str = "",
    video_duration_hint: float = 0.0,
    min_split_size: int = MIN_SPLIT_SIZE,
) -> None:
    """Translate one chunk, and if Gemini's reply can't be parsed, split
    the batch in half and translate each half separately.

    A single request covering 100+ lines is the likeliest way to hit an
    unusable reply: Uzbek text is token-heavy, so the JSON answer can be
    cut off at the output limit, and a very long structured reply is also
    more likely to come back malformed at random. Halving the batch fixes
    both — a shorter answer fits, and a retry is a fresh sample. Only
    parse/shape failures trigger this (BAD_GEMINI_JSON /
    BAD_TRANSLATION_SHAPE); network errors and rate limits are already
    handled inside call_gemini_json, and splitting wouldn't help them.

    Both halves reuse the same audio file: it's already within the size
    budget, and the prompt only lists that half's lines, so the model
    simply translates the lines it's given. Recursion stops once a batch
    is smaller than min_split_size, so it can't loop forever and a
    genuinely unfixable failure still surfaces instead of being hidden.
    """
    try:
        await _translate_one_chunk_attempt(
            segments, target_language, language_code, source_video,
            chunk_label=chunk_label, video_duration_hint=video_duration_hint,
        )
        return
    except HTTPException as exc:
        detail = exc.detail if isinstance(exc.detail, dict) else {}
        recoverable = detail.get("code") in ("BAD_GEMINI_JSON", "BAD_TRANSLATION_SHAPE")
        if not recoverable or len(segments) < min_split_size * 2:
            raise
        middle = len(segments) // 2
        print(f"[translate] Chunk {chunk_label or '1/1'}: unusable reply for {len(segments)} lines "
              f"({detail.get('code')}) — splitting into {middle} + {len(segments) - middle} and retrying", flush=True)

    await asyncio.sleep(5)
    for half_number, half in enumerate((segments[:middle], segments[middle:]), start=1):
        await _translate_one_chunk(
            half, target_language, language_code, source_video,
            chunk_label=f"{chunk_label}.{half_number}" if chunk_label else f"split.{half_number}",
            video_duration_hint=video_duration_hint, min_split_size=min_split_size,
        )
        if half_number == 1:
            await asyncio.sleep(5)  # space out requests, same reason as between chunks


async def _translate_one_chunk_attempt(
    segments: list[dict[str, Any]],
    target_language: str,
    language_code: str,
    source_video: Path | None,
    chunk_label: str = "",
    video_duration_hint: float = 0.0,
) -> None:
    """One translation request for one batch of segments (see
    _translate_one_chunk for the retry-by-splitting wrapper, and
    translate_segments_pass for the chunking/extraction rationale). Indices
    in the prompt are local to this batch, so results map straight back
    onto the passed-in slice. source_video here is an already-extracted
    audio file (and, for a multi-chunk video, already cut to this chunk's
    range) — no further extraction happens in this function."""
    items = [
        {"index": index, "speaker": segment.get("speaker_id", ""), "text": segment["original"]}
        for index, segment in enumerate(segments)
    ]
    orthography_note = ""
    if target_language.lower().startswith("uzbek"):
        orthography_note = (
            "\n\nUzbek spelling rule: the apostrophe (') is a real letter in Uzbek "
            "orthography (as in o', g', and words like bo'lish, ko'proq, o'zim, tug'ilgan). "
            "Always use the correct apostrophe wherever standard Uzbek spelling requires "
            "it — do not drop it or replace it with a plain vowel."
        )

    audio_instruction = ""
    media_parts: list[dict[str, Any]] = []
    if source_video is not None and source_video.exists():
        # source_video here is actually an extracted AUDIO file (aac) — the
        # parameter name is kept for compatibility with the caller, but
        # this reads/attaches audio, not video. Already extracted (and,
        # for a multi-chunk video, already cut to this chunk's range) by
        # translate_segments_pass.
        try:
            audio_bytes = source_video.read_bytes()
        except Exception:
            audio_bytes = b""
        # Vertex AI's official inline-data limit is 20MB for the TOTAL
        # request payload (not ~100MB as earlier assumed — see
        # cloud.google.com/vertex-ai/generative-ai/docs/model-reference/gemini,
        # "Size limit: 20MB"). Base64 encoding inflates raw bytes by ~33%,
        # so the raw file needs to stay under ~15MB to land the encoded
        # payload under that ceiling. Skip silently (fall back to
        # text-only) if still oversized after chunking.
        if audio_bytes and len(audio_bytes) <= 15 * 1024 * 1024:
            media_parts.append({"inlineData": {"mimeType": "audio/aac", "data": base64.b64encode(audio_bytes).decode("ascii")}})
            audio_instruction = (
                "\n\nYou can also hear the actual audio this dialogue comes from. Listen to each line's "
                "delivery closely — tone of voice, volume, pace, pauses, hesitation, genuine emotion vs. a flat "
                "or sarcastic delivery — and use that to translate what the line actually MEANS, not just a "
                "literal word-for-word rendering. For example: sarcasm delivered in a flat monotone vs. genuine "
                "sincerity, a raised or trembling voice signaling anger or fear that a neutral literal "
                "translation would flatten, or a hesitant pause suggesting doubt. The translation must still "
                "match rules 1-9 below exactly — audio context should sharpen accuracy, never license inventing "
                "meaning that isn't actually there in the words or the delivery. Also use the voices to tell "
                "whether each speaker is male or female (see rule 9)."
            )
        else:
            print(f"[translate] Audio too large or unreadable for context ({len(audio_bytes) / 1024 / 1024:.0f}MB), falling back to text-only translation", flush=True)

    prompt = f"""You are a senior professional dubbing translator with 20 years of experience. Below is a full conversation, in order, with each line's speaker and original text. Accuracy is critical — this translation will be used for voice dubbing and every viewer must understand exactly what was said.{audio_instruction}

STRICT RULES (violating any of these is a failure):
1. Translate the FULL meaning of each line — never drop clauses, qualifiers, negations, or details to make the sentence shorter or smoother. A shorter translation that loses information is wrong even if it sounds more natural.
2. Preserve exact tense and aspect (past/present/future, completed/ongoing) — infer this from context across the whole conversation, not from one line in isolation.
3. Preserve who is speaking to whom, and any pronouns referring to specific people mentioned earlier in the conversation. Do not swap or lose track of subjects/objects between lines.
4. Preserve names, numbers, quantities, and specific facts EXACTLY — do not approximate, round, or generalize them.
5. Do not add meaning that was not in the original (no invented details, no softened or intensified emotion beyond what the words say).
6. Do not remove idiomatic force — if the original is blunt, sarcastic, or emotionally loaded, the translation must carry the same force in natural {target_language}, not a flattened literal version.
7. Translate naturally for spoken dubbing (not robotic word-for-word), but "natural" never overrides rules 1-6 — natural phrasing must still carry 100% of the original meaning.
8. The text goes straight to a speech synthesizer: write every number, year, date, time, amount, percentage and unit out in WORDS exactly as a {target_language} speaker would say it aloud (e.g. "25%" -> the {target_language} words for "twenty-five percent"). The value itself must stay exactly the same (rule 4).
9. If {target_language} grammar marks gender (verb endings, adjectives, forms of address), work out each speaker's gender — from their voice if you can hear the audio, otherwise from context — and keep it consistent for that speaker in every line, both when they talk about themselves and when others address them.

Before answering, silently re-check every line against its original: did you drop or change anything the speaker actually said? If yes, fix it before responding.

Do not add commentary. Do not merge or split lines. Keep the same "index" for each line — return exactly one translation per input line, in the same order.{orthography_note}

CONVERSATION (in order):
{json.dumps(items, ensure_ascii=False)}

Return JSON only, in this exact shape:
{{"translations": [{{"index": 0, "text": "translated text"}}]}}"""

    # Scale the timeout to the video's length — Gemini needs proportionally
    # longer to watch a longer clip, and a fixed 180s was timing out on
    # anything but short videos. Roughly 3x the video's own duration (so a
    # 5-minute clip gets 15 minutes), with a 180s floor for short clips and
    # a 30-minute ceiling so a stuck request still fails in reasonable time
    # rather than hanging indefinitely.
    timeout_seconds = 180
    if video_duration_hint > 0:
        timeout_seconds = int(min(1800, max(180, video_duration_hint * 3)))

    if chunk_label:
        print(f"[translate] Chunk {chunk_label}: translating {len(segments)} lines"
              f"{' with audio context' if media_parts else ' (text only)'}"
              f", timeout {timeout_seconds}s", flush=True)

    parsed = await call_gemini_json(
        prompt, timeout=timeout_seconds, media_parts=media_parts or None,
        label=f"translate {chunk_label}" if chunk_label else "translate",
    )
    try:
        translations = {int(item["index"]): str(item["text"]) for item in parsed["translations"]}
    except Exception as exc:
        raise HTTPException(500, {"code": "BAD_TRANSLATION_SHAPE", "message": f"Неверный формат перевода: {exc}"}) from exc

    # Lines Gemini silently skipped would otherwise be filled with the
    # ORIGINAL untranslated text and go to voicing as-is, with nothing in
    # the log. A few misses get a warning; if a large share is missing
    # (the model gave up part-way) and the batch is big enough to split,
    # treat it as an unusable reply so the wrapper retries in halves.
    missing = [index for index in range(len(segments)) if index not in translations]
    if missing:
        print(f"[translate] WARNING: Gemini returned no translation for {len(missing)}/{len(segments)} lines "
              f"(indices {missing[:10]}{'...' if len(missing) > 10 else ''}) — those keep the original text", flush=True)
        if len(missing) > len(segments) * 0.1 and len(segments) >= MIN_SPLIT_SIZE * 2:
            raise HTTPException(500, {"code": "BAD_TRANSLATION_SHAPE",
                                      "message": f"Gemini пропустил {len(missing)} из {len(segments)} реплик"})

    for index, segment in enumerate(segments):
        segment["translated"] = translations.get(index, segment["original"])


# The review/length passes work on the FINISHED translation, one request per
# batch of consecutive lines instead of one request for the whole video.
# With 346 lines a single request overran its 180s limit, was retried
# unchanged (a size problem, so the retry failed the same way) and — worse —
# its failure threw away a translation that had already succeeded. Batches
# keep each request small and fast, a longer limit covers a slow reply, and
# only 2 attempts are made because repeating an identical request that timed
# out rarely helps. Lines keep their GLOBAL index inside a batch, so Gemini's
# answers map straight back onto the full list.
REFINE_BATCH_SIZE = 50
REFINE_TIMEOUT_SECONDS = 300
REFINE_MAX_ATTEMPTS = 2


def _refine_batches(items: list[dict[str, Any]]) -> list[list[dict[str, Any]]]:
    return [items[i:i + REFINE_BATCH_SIZE] for i in range(0, len(items), REFINE_BATCH_SIZE)]


def _length_ceiling(segment: dict[str, Any], max_extra: float) -> float:
    """Самая большая допустимая «длина произношения» перевода: как у оригинала
    плюс max_extra (в латинских буквах). Одна мерка на все три шага."""
    return speech_weight(segment["original"]) + max_extra


def _uzbek_note(target_language: str) -> str:
    if not target_language.lower().startswith("uzbek"):
        return ""
    return ("In Uzbek, the apostrophe (') is a real letter (as in o', g', bo'lish, ko'proq) — always use correct "
            "standard Uzbek spelling, including the apostrophe wherever it belongs.")


async def fit_translation_length_pass(
    segments: list[dict[str, Any]],
    target_language: str,
    max_extra_letters: int = 5,
    max_attempts: int = 3,
    only_indices: set[int] | None = None,
) -> None:
    """Pass 2: shorten only the translations that are too long, in a
    dedicated request focused purely on length — separated from the
    translation pass so it doesn't compromise meaning.

    "Too long" is measured with speech_weight (the same per-script weights
    OmniVoice uses to time its speech), not raw letters: a Japanese or
    Korean line is not "short" just because each character is a syllable.
    Gemini still gets a plain letter limit, converted into the target
    script by letters_for_weight.

    Punctuation (.,;:—–-) is KEPT, not stripped. OmniVoice relies on it
    for natural pacing, intonation rises on questions, and sentence-final
    closure.

    only_indices: limit the pass to these lines (used after the review
    pass, so lines that were already handled are not sent again).
    """
    for segment in segments:
        segment["translated"] = re.sub(r"\s+", " ", segment["translated"]).strip()

    for _ in range(max_attempts):
        overlong = []
        for index, segment in enumerate(segments):
            if only_indices is not None and index not in only_indices:
                continue
            ceiling = _length_ceiling(segment, max_extra_letters)
            if speech_weight(segment["translated"]) <= ceiling:
                continue
            overlong.append({
                "index": index,
                "original": segment["original"],
                "current_translation": segment["translated"],
                "max_letters": letters_for_weight(segment["translated"], ceiling),
            })
        if not overlong:
            return

        batches = _refine_batches(overlong)
        for number, batch in enumerate(batches, start=1):
            prompt = f"""You are a professional {target_language} dubbing editor. Some translations below are too long for dubbing timing.
Rewrite each "current_translation" into a SHORTER natural {target_language} phrase that preserves the complete meaning.
Each rewritten text must have no more than "max_letters" Unicode letters (spaces/punctuation/digits do not count).
Use natural punctuation (periods, commas, question marks, exclamation marks) as appropriate for meaning and pacing — the voice engine relies on it for natural intonation.
Keep numbers written out as words, exactly as in the current translation.
{_uzbek_note(target_language)}
Count letters yourself before answering. Never omit an item or change its index.

INPUT:
{json.dumps(batch, ensure_ascii=False)}

Return JSON only, in this exact shape:
{{"translations": [{{"index": 0, "text": "shorter translation"}}]}}"""

            parsed = await call_gemini_json(
                prompt, timeout=REFINE_TIMEOUT_SECONDS, max_attempts=REFINE_MAX_ATTEMPTS,
                label=f"shorten {number}/{len(batches)}",
            )
            try:
                shortened = {int(item["index"]): str(item["text"]) for item in parsed["translations"]}
            except Exception:
                continue  # keep this batch as is; the other batches may still be fine

            for index, text in shortened.items():
                if not 0 <= index < len(segments):
                    continue  # Gemini returned an index we never sent
                clean = re.sub(r"\s+", " ", text).strip()
                if clean and speech_weight(clean) < speech_weight(segments[index]["translated"]):
                    segments[index]["translated"] = clean


async def expand_short_translations_pass(
    segments: list[dict[str, Any]],
    target_language: str,
    min_ratio: float = 0.8,
    target_ratio: float = 0.9,
    max_extra_letters: int = 5,
    min_original_letters: int = 12,
    max_attempts: int = 2,
) -> None:
    """Pass 2b: lengthen translations that came out noticeably SHORTER
    than the original, so the dubbed line doesn't finish while the speaker
    on screen is still talking.

    The mirror image of fit_translation_length_pass, built on the SAME
    measure (speech_weight vs. the original) and the SAME ceiling, so the
    two passes can't fight each other: an expansion is only accepted if it
    stays at or under the shortening pass's ceiling.

    Very short originals (speech weight under min_original_letters —
    interjections like "Hm", "Yes!", "E!") are skipped: the ratio is noise
    at that size, and inflating a one-word reply would be wrong.

    Lengthening must never add meaning — the prompt restricts Gemini to
    fuller natural phrasing of the SAME content; the review pass that runs
    afterwards is a second safety net.
    """
    for _ in range(max_attempts):
        short = []
        for index, segment in enumerate(segments):
            original_weight = speech_weight(segment["original"])
            translated_weight = speech_weight(segment["translated"])
            if original_weight < min_original_letters:
                continue
            if translated_weight >= original_weight * min_ratio:
                continue
            ceiling = _length_ceiling(segment, max_extra_letters)
            short.append({
                "index": index,
                "original": segment["original"],
                "current_translation": segment["translated"],
                "min_letters": max(1, math.ceil(letters_for_weight(segment["translated"], original_weight * target_ratio))),
                "max_letters": letters_for_weight(segment["translated"], ceiling),
            })
        if not short:
            return

        print(f"[translate-expand] {len(short)} line(s) noticeably shorter than the original — asking Gemini to lengthen", flush=True)

        batches = _refine_batches(short)
        applied = 0
        for number, batch in enumerate(batches, start=1):
            prompt = f"""You are a professional {target_language} dubbing editor. The translations below are noticeably SHORTER than the original speech, so the dubbed voice finishes while the speaker on screen is still talking.
Rewrite each "current_translation" into a LONGER, fully natural spoken {target_language} phrase with EXACTLY the same meaning.
Each rewritten text should have between "min_letters" and "max_letters" Unicode letters (spaces/punctuation/digits do not count). Never exceed "max_letters".

How to lengthen WITHOUT changing meaning:
- Use fuller, complete forms instead of clipped or overly compact ones.
- Use natural connecting words and fuller sentence structure a native speaker would genuinely use when saying this out loud.
- Keep the same tone (blunt stays blunt, casual stays casual, sarcastic stays sarcastic).

STRICTLY FORBIDDEN:
- Adding any fact, name, number, event, reason, or detail that is not in the original.
- Adding emotion or emphasis that is not in the original.
- Changing tense, who is speaking to whom, or what is being referred to.
If a line cannot be lengthened without adding meaning, return it unchanged.

Use natural punctuation (periods, commas, question marks, exclamation marks) — the voice engine relies on it for natural intonation.
Keep numbers written out as words.
{_uzbek_note(target_language)}
Count letters yourself before answering. Never omit an item or change its index.

INPUT:
{json.dumps(batch, ensure_ascii=False)}

Return JSON only, in this exact shape:
{{"translations": [{{"index": 0, "text": "longer translation"}}]}}"""

            parsed = await call_gemini_json(
                prompt, timeout=REFINE_TIMEOUT_SECONDS, max_attempts=REFINE_MAX_ATTEMPTS,
                label=f"lengthen {number}/{len(batches)}",
            )
            try:
                expanded = {int(item["index"]): str(item["text"]) for item in parsed["translations"]}
            except Exception:
                continue  # keep this batch as is; the other batches may still be fine

            for index, text in expanded.items():
                if not 0 <= index < len(segments):
                    continue
                clean = re.sub(r"\s+", " ", text).strip()
                if not clean:
                    continue
                current_weight = speech_weight(segments[index]["translated"])
                new_weight = speech_weight(clean)
                # Accept only a genuine lengthening that stays within the
                # shortening pass's ceiling — never let an expansion undo what
                # fit_translation_length_pass guarantees.
                if current_weight < new_weight <= _length_ceiling(segments[index], max_extra_letters):
                    segments[index]["translated"] = clean
                    applied += 1
        if applied == 0:
            return  # Nothing usable came back — stop instead of spending another attempt.


async def reflect_and_fix_translation_pass(
    segments: list[dict[str, Any]], target_language: str, max_attempts: int = 1, max_extra_letters: int = 5
) -> set[int]:
    """Pass 3 ("Reflect"): a dedicated self-review of the finished
    translation, looking for actual errors rather than producing a fresh
    translation from scratch (VideoLingo's Translate-Reflect-Adaptation).

    Deliberately conservative: Gemini is told to flag ONLY lines with a
    real problem and leave everything else untouched.

    Each line now carries its "max_letters" budget too, so a fix keeps to
    the dubbing length where it can. A fix that restores real meaning is
    still accepted even if it runs long — losing a negation is worse than a
    long line; translate_segments then shortens just those lines once more.
    Returns the indices of corrected lines.
    """
    corrected: set[int] = set()
    for _ in range(max_attempts):
        items = [
            {
                "index": index,
                "original": segment["original"],
                "translation": segment["translated"],
                "max_letters": max(
                    letter_count(segment["translated"]),
                    letters_for_weight(segment["translated"], _length_ceiling(segment, max_extra_letters)),
                ),
            }
            for index, segment in enumerate(segments)
        ]

        batches = _refine_batches(items)
        applied = 0
        for number, batch in enumerate(batches, start=1):
            prompt = f"""You are a senior dubbing translation QA reviewer. Below is a finished {target_language} translation of a conversation, alongside each line's original text. Your job is to find and fix ONLY real errors — this is a review pass, not a re-translation.

For each line, check:
- Did the translation drop or distort any part of the original's meaning?
- Is the tense/aspect correct (past/present/future, completed/ongoing)?
- Is the tone right (if the original is blunt/sarcastic/emotional, does the translation carry that, or did it get flattened)?
- Is the grammar in {target_language} actually correct (this matters especially for any line that was shortened for timing — shortening sometimes breaks grammar)?
- Are names, numbers, and specific facts preserved exactly? (Numbers are intentionally written out as words for the voice engine — that is correct, not an error.)

Only include a line in your response if you are fixing a genuine error. Do NOT rewrite lines that are already correct just to change their style or wording — leave those out entirely. Do NOT second-guess a correct translation because a different phrasing is also possible; only flag actual mistakes.
A corrected line should stay within its "max_letters" (Unicode letters only) — it is dubbed into a fixed time slot.

CONVERSATION (original + current translation):
{json.dumps(batch, ensure_ascii=False)}

Return JSON only, listing ONLY the lines you are correcting, in this exact shape:
{{"fixes": [{{"index": 3, "text": "corrected translation"}}]}}
If no lines need correction, return {{"fixes": []}}."""

            parsed = await call_gemini_json(
                prompt, timeout=REFINE_TIMEOUT_SECONDS, max_attempts=REFINE_MAX_ATTEMPTS,
                label=f"review {number}/{len(batches)}",
            )
            try:
                fixes = {int(item["index"]): str(item["text"]) for item in parsed.get("fixes", [])}
            except Exception:
                continue  # keep this batch as is; the other batches may still be fine

            for index, text in fixes.items():
                if 0 <= index < len(segments):
                    clean = re.sub(r"\s+", " ", text).strip()
                    if clean and clean != segments[index]["translated"]:
                        print(f"[translate-reflect] seg_{index} corrected: {segments[index]['translated']!r} -> {clean!r}", flush=True)
                        segments[index]["translated"] = clean
                        corrected.add(index)
                        applied += 1
        if applied == 0:
            break  # Nothing to fix — stop early instead of spending another attempt.
    return corrected


async def translate_segments(
    segments: list[dict[str, Any]], target_language: str, language_code: str, source_video: Path | None = None
) -> None:
    """Translate every segment's `original` text into `translated`, in place.

    Runs as focused passes instead of one overloaded prompt —
    VideoLingo's "Translate-Reflect-Adaptation" technique:
    1. An accurate, audio-aware translation via Gemini with full dialogue
       context.
    2. Length fitting in both directions, on one shared yardstick
       (speech_weight):
       2a. shorten lines that run too long for their slot;
       2b. lengthen lines that came out noticeably too short.
    3. A "reflect" pass that reviews the FINISHED translation against the
       originals and fixes only genuine errors. If a fix made a line too
       long again, that line alone gets one more shortening attempt.
    """
    if not segments:
        return
    if not gemini_config()["key"]:
        raise HTTPException(500, {"code": "NO_GEMINI_KEY", "message": "Ключ Gemini не задан в .env (AI_STUDIO_API_KEY=...)"})

    await translate_segments_pass(segments, target_language, language_code, source_video=source_video)

    # Steps 2-3 only IMPROVE a translation that already exists. If one of
    # them fails, keep what we have instead of failing the whole request —
    # otherwise a timeout in an optional review step throws away minutes of
    # finished (and paid-for) translation. Lines improved by earlier batches
    # stay improved.
    #
    # After a failure that points at the service itself (can't reach it,
    # rejected, rate-limited), the remaining steps are skipped: they'd hit
    # the same wall and each would burn its own full timeout.
    corrected: set[int] = set()

    async def review_step(items: list[dict[str, Any]], language: str) -> None:
        corrected.update(await reflect_and_fix_translation_pass(items, language))

    async def reshorten_step(items: list[dict[str, Any]], language: str) -> None:
        if corrected:
            await fit_translation_length_pass(items, language, max_attempts=1, only_indices=corrected)

    refinement_steps = (
        ("shorten", fit_translation_length_pass),
        ("lengthen", expand_short_translations_pass),
        ("review", review_step),
        ("re-shorten reviewed lines", reshorten_step),
    )
    for name, run_step in refinement_steps:
        try:
            await run_step(segments, target_language)
        except Exception as exc:
            detail = exc.detail if isinstance(getattr(exc, "detail", None), dict) else {}
            reason = str(detail.get("message") or exc)[:200].replace("\n", " ")
            print(f"[translate] WARNING: step '{name}' failed ({reason}) — the finished translation is kept as is", flush=True)
            if detail.get("code") in ("GEMINI_UNREACHABLE", "GEMINI_ERROR"):
                print("[translate] Gemini is not answering reliably — skipping the remaining refinement steps", flush=True)
                break


# ---------------------------------------------------------------------------
# Combined pipeline endpoint
# ---------------------------------------------------------------------------


@app.post("/api/translate")
async def translate(request: Request) -> dict[str, Any]:
    """Transcribe with Scribe (accurate timings), then translate with Gemini."""
    body = await request.json()
    source = UPLOADS / Path(body.get("filename", "")).name
    language_code = str(body.get("lang", "uz"))
    if language_code not in LANGS:
        language_code = "uz"
    target_language = LANGS[language_code]

    if not source.exists():
        raise HTTPException(404, "Файл не найден")

    # Cache Scribe's RAW word-level output (+ the speaker-gender read, also
    # a paid Gemini call) next to the uploaded video, keyed by filename.
    # Without this, every retry after a translation failure (e.g. Gemini's
    # 429/timeout — the reason this cache was added) would re-run Scribe
    # and burn ElevenLabs quota on a transcription that hasn't changed.
    #
    # The cache holds the RAW words, not the grouped segments, on purpose:
    # grouping words into sentences is our own logic and has changed
    # several times (see group_words_into_segments). If the cache held the
    # grouped result, every such change would be invisible for any video
    # already cached, and applying it would mean paying for Scribe again.
    # Grouping raw words is instant and free, so it's redone on every run.
    #
    # force_retranscribe lets the person explicitly bypass this (e.g.
    # Scribe itself mis-heard something).
    force_retranscribe = parse_bool(body.get("forceRetranscribe"), False)
    cache_path = UPLOADS / f"{source.stem}_transcript_cache.json"
    scribe_result = None
    genders: dict[str, str] = {}
    if cache_path.exists() and not force_retranscribe:
        try:
            cached = json.loads(cache_path.read_text())
            if "scribe_result" in cached:
                scribe_result = cached["scribe_result"]
                genders = cached.get("genders") or {}
                print(f"[translate] Reusing cached Scribe transcription for '{source.name}' — no ElevenLabs call made", flush=True)
            else:
                # Old cache format (grouped segments only, no raw words):
                # can't be regrouped, so it has to be rebuilt once.
                print(f"[translate] Cache for '{source.name}' is in the old format (no raw words) — "
                      f"transcribing once more so sentence splitting can apply", flush=True)
        except Exception:
            cache_path.unlink(missing_ok=True)  # corrupt cache — rebuild it below

    if scribe_result is None:
        with tempfile.TemporaryDirectory(prefix="jarcut2_") as temp_dir:
            audio_path = Path(temp_dir) / "audio.mp3"
            # После очистки (шаг 0) Scribe слушает чистый голос: без музыки и
            # шума он точнее ставит границы слов и реже путает спикеров.
            stems = load_stems(source)
            if stems:
                print("[translate] Распознаю очищенный голос (после шага очистки)", flush=True)
            if not await asyncio.to_thread(extract_audio, stems["vocals_clean"] if stems else source, audio_path):
                raise HTTPException(500, {"code": "AUDIO_EXTRACT_FAILED", "message": "Не удалось извлечь аудио (проверьте ffmpeg)"})

            scribe_result = await transcribe_with_scribe(audio_path)
            # Keep only what grouping needs; Scribe's full response carries
            # per-character data that would make the cache file huge.
            scribe_result = {"words": [
                {key: word[key] for key in ("text", "start", "end", "type", "speaker_id", "speaker") if key in word}
                for word in (scribe_result.get("words") or [])
            ]}

            first_pass = group_words_into_segments(scribe_result, verbose=False)
            if not first_pass:
                return {"ok": True, "segments": [], "speakers": [], "languageCode": language_code, "targetLanguage": target_language}
            # Пол спикеров через Gemini больше не определяется: он нужен был только
            # для выбора голоса Gemini TTS, а OmniVoice клонирует голос из
            # оригинала. Это экономит один тяжёлый запрос со всем аудио видео.
            genders = {}

        try:
            cache_path.write_text(json.dumps({"scribe_result": scribe_result, "genders": genders}, ensure_ascii=False))
        except Exception as exc:
            print(f"[translate] Failed to write transcript cache (non-fatal): {exc}", flush=True)

    segments = group_words_into_segments(scribe_result)
    if not segments:
        return {"ok": True, "segments": [], "speakers": [], "languageCode": language_code, "targetLanguage": target_language}
    raw_speaker_ids: list[str] = []
    for segment in segments:
        if segment["speaker_id"] not in raw_speaker_ids:
            raw_speaker_ids.append(segment["speaker_id"])

    # No separate Gemini intonation analysis: with OmniVoice cloning the
    # speaker's own voice directly from a reference clip (see
    # synthesize_line / choose_reference_indices), the
    # delivery/emotion comes from the actual audio itself, not from a
    # text-tag description layered on top — that step is now redundant.
    intonations: dict[int, str] = {}

    await translate_segments(segments, target_language, language_code, source_video=source)

    # Assign stable speaker ids (S1, S2, ...) and a voice matching the
    # detected vocal gender, so masculine/feminine voices don't get swapped.
    speaker_order = raw_speaker_ids
    used_voices: set[str] = set()
    speaker_voice: dict[str, str] = {}
    for raw_id in speaker_order:
        character = genders.get(raw_id, "neutral")
        pool = MASCULINE_VOICES if character == "masculine" else FEMININE_VOICES if character == "feminine" else VOICE_POOL
        voice = next((candidate for candidate in pool if candidate not in used_voices), None)
        if voice is None:
            voice = next((candidate for candidate in VOICE_POOL if candidate not in used_voices), VOICE_POOL[0])
        used_voices.add(voice)
        speaker_voice[raw_id] = voice
    speakers = [
        {"id": f"S{index + 1}", "label": f"Спикер {index + 1}", "voice": speaker_voice[raw_id]}
        for index, raw_id in enumerate(speaker_order)
    ]
    id_map = {raw_id: f"S{index + 1}" for index, raw_id in enumerate(speaker_order)}

    for index, segment in enumerate(segments):
        segment["id"] = f"seg_{index}"
        segment["speaker_id"] = id_map[segment["speaker_id"]]
        segment["voice"] = speaker_voice_by_safe_id(speakers, segment["speaker_id"])
        segment["start"] = round(segment["start"], 3)
        segment["end"] = round(segment["end"], 3)
        segment["duration"] = round(max(0.3, segment["end"] - segment["start"]), 3)
        segment["intonation"] = intonations.get(index, "")

    return {
        "ok": True,
        "languageCode": language_code,
        "targetLanguage": target_language,
        "speakers": speakers,
        "segments": segments,
    }


def speaker_voice_by_safe_id(speakers: list[dict[str, Any]], safe_id: str) -> str:
    for speaker in speakers:
        if speaker["id"] == safe_id:
            return speaker["voice"]
    return "Kore"


# ---------------------------------------------------------------------------
# Step 3: озвучка — OmniVoice на Colab
# ---------------------------------------------------------------------------


def probe_duration(path: Path) -> float:
    try:
        result = subprocess.run(
            ["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "default=nw=1:nk=1", str(path)],
            capture_output=True, text=True, timeout=30,
        )
        return max(0.0, float(result.stdout.strip())) if result.returncode == 0 else 0.0
    except (ValueError, FileNotFoundError, subprocess.TimeoutExpired):
        return 0.0


_ANALYSIS_SAMPLE_RATE = 16000
_SILENCE_FLOOR = 10 ** (-45 / 20)      # never treat anything quieter than -45 dBFS as voice
_SILENCE_RELATIVE = 10 ** (-35 / 20)   # ...nor anything 35 dB below the clip's own loud level
_MIN_VOICE_FRAMES = 5                  # 5 x 10ms: a blip shorter than 50ms is noise, not speech


def decode_mono_16k(path: Path) -> "np.ndarray | None":
    """Decode any audio file to mono float32 at 16 kHz, or None on failure.
    Analysis only — the file itself is never re-encoded through this."""
    try:
        result = subprocess.run(
            ["ffmpeg", "-v", "error", "-i", str(path), "-f", "f32le", "-ac", "1",
             "-ar", str(_ANALYSIS_SAMPLE_RATE), "-"],
            capture_output=True, timeout=60,
        )
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return None
    usable = (len(result.stdout) // 4) * 4
    if result.returncode != 0 or usable == 0:
        return None
    return np.frombuffer(result.stdout[:usable], dtype=np.float32)


def find_voice_span(samples: "np.ndarray", sample_rate: int = _ANALYSIS_SAMPLE_RATE) -> "tuple[float, float] | None":
    """Return (onset_seconds, offset_seconds) of the audible part of a clip,
    or None if it has no audible content at all.

    The threshold is the LOUDER of a fixed floor (-45 dBFS) and a level
    relative to the clip's own loud parts. A fixed floor alone fails on a
    clip with a steady low hiss just above it (every frame then "sounds
    like voice" and nothing is ever trimmed); the relative part follows
    such a noise floor. The loud reference is a high percentile rather than
    the maximum so one stray click can't push the threshold up and make
    real speech look like silence. Because callers keep a margin of silence
    beyond these edges, a slightly aggressive threshold cannot clip a word.
    """
    frame = max(1, int(sample_rate * 0.01))
    frames = samples.size // frame
    if frames == 0:
        return None
    peaks = np.abs(samples[: frames * frame]).reshape(frames, frame).max(axis=1)
    reference = float(np.percentile(peaks, 99))
    if reference <= 0.0:
        return None
    loud = peaks > max(_SILENCE_FLOOR, reference * _SILENCE_RELATIVE)
    if not loud.any():
        return None

    need = min(_MIN_VOICE_FRAMES, int(loud.sum()))
    if need > 1:
        runs = np.convolve(loud.astype(np.int32), np.ones(need, dtype=np.int32), mode="valid") == need
    else:
        runs = loud
    if runs.any():
        first = int(np.argmax(runs))
        last = int(runs.size - 1 - np.argmax(runs[::-1])) + need - 1
    else:  # only scattered blips, no sustained sound: fall back to the loud frames themselves
        first = int(np.argmax(loud))
        last = int(loud.size - 1 - np.argmax(loud[::-1]))
    return first * frame / sample_rate, (last + 1) * frame / sample_rate


def analyze_clip(path: Path) -> tuple[float, float, float]:
    """(длина, тишина в начале, тишина в конце) за ОДНО декодирование.
    Раньше на каждый клип запускались ffprobe и ffmpeg по очереди."""
    samples = decode_mono_16k(path)
    if samples is None:
        return probe_duration(path), 0.0, 0.0
    total = samples.size / _ANALYSIS_SAMPLE_RATE
    span = find_voice_span(samples)
    if span is None:
        return total, 0.0, 0.0
    return total, span[0], max(0.0, total - span[1])


def measure_edge_silence(path: Path) -> tuple[float, float]:
    """(leading_silence, trailing_silence) in seconds. (0, 0) if it can't be
    measured — callers then behave as if the whole file were voice."""
    samples = decode_mono_16k(path)
    if samples is None:
        return 0.0, 0.0
    span = find_voice_span(samples)
    if span is None:
        return 0.0, 0.0
    total = samples.size / _ANALYSIS_SAMPLE_RATE
    return span[0], max(0.0, total - span[1])


def trim_edge_silence(source: Path, target: Path, keep_seconds: float | None = None) -> bool:
    """Cap the silence at the START and END of a generated line at
    keep_seconds (default EDGE_SILENCE_KEEP_SECONDS): silence up to that
    long is left untouched, silence beyond it is cut down to exactly that
    length. Never touches anything between the first and last audible sound.

    Returns True if `target` was written (either the trimmed clip, or an
    unchanged copy when nothing needed cutting), False if the clip couldn't
    be analysed — the caller then keeps the original untouched.

    No fade is applied: the cut always lands keep_seconds away from the
    voice, inside silence. The earlier version cut right at the voice edge
    and needed a fade to hide the chopped decay; that problem no longer
    exists, and a fade inside silence would do nothing.
    """
    keep = EDGE_SILENCE_KEEP_SECONDS if keep_seconds is None else max(0.05, keep_seconds)
    samples = decode_mono_16k(source)
    if samples is None:
        return False
    total = samples.size / _ANALYSIS_SAMPLE_RATE
    span = find_voice_span(samples)
    if span is None:
        print(f"[trim] {source.name}: no audible sound found in a {total:.2f}s clip — left as is", flush=True)
        return False

    onset, offset = span
    cut_start = max(0.0, onset - keep)
    cut_end = min(total, offset + keep)
    lead, tail = onset, max(0.0, total - offset)

    if cut_start <= 0.0 and cut_end >= total:
        target.write_bytes(source.read_bytes())  # nothing exceeds the limit
        return target.exists() and target.stat().st_size > 44

    print(f"[trim] voice {onset:.2f}-{offset:.2f}s of {total:.2f}s: "
          f"silence at start {lead:.2f}s -> {min(lead, keep):.2f}s, at end {tail:.2f}s -> {min(tail, keep):.2f}s", flush=True)
    try:
        result = subprocess.run(
            ["ffmpeg", "-y", "-i", str(source), "-af",
             f"atrim=start={cut_start:.4f}:end={cut_end:.4f},asetpts=PTS-STARTPTS", str(target)],
            capture_output=True, text=True, timeout=60,
        )
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return False
    return result.returncode == 0 and target.exists() and target.stat().st_size > 44


# ---- Клиент Colab-сервера -------------------------------------------------------


class GpuError(Exception):
    """Colab не ответил или ответил ошибкой. Текст — уже по-русски, для лога."""

    def __init__(self, message: str, code: str = "GPU_ERROR", status: int = 0) -> None:
        super().__init__(message)
        self.code = code
        self.status = status


def gpu_endpoint() -> tuple[str, str] | None:
    """(адрес, ключ) из JARCUT_GPU_URL, или None, если ссылка не задана.

    Читается через env_now: .env перечитывается, когда файл меняется, и
    строка, УДАЛЁННАЯ из .env, перестаёт действовать. Раньше в этом случае
    молча бралось старое значение, которое load_dotenv положил в окружение
    при запуске server.py.
    """
    raw = env_now(GPU_URL_ENV_NAME)
    if not raw:
        return None
    if "://" not in raw:
        raw = "https://" + raw
    parts = urlsplit(raw)
    key = (parse_qs(parts.query).get("key") or [""])[0]
    base = f"{parts.scheme}://{parts.netloc}{parts.path}".rstrip("/")
    return base, key


# Ответы туннеля Cloudflare, когда сервер за ним уже не работает.
_TUNNEL_DOWN_STATUSES = {502, 503, 504, 520, 521, 522, 523, 524, 525, 526, 527, 530}


def _gpu_error_message(response: httpx.Response) -> tuple[str, str]:
    try:
        data = response.json()
        message = data.get("error") or data.get("detail") or data
        return str(message)[:600], str(data.get("code") or "GPU_ERROR")
    except Exception:
        return (" ".join(response.text.split())[:300] or f"HTTP {response.status_code}"), "GPU_ERROR"


async def gpu_request(method: str, path: str, *, timeout: float = 60, **kwargs: Any) -> httpx.Response:
    endpoint = gpu_endpoint()
    if endpoint is None:
        raise GpuError("JARCUT_GPU_URL не задан в .env — запусти Colab-ноутбук и вставь строку, которую он напечатал", "NO_GPU_URL")
    base, key = endpoint
    headers = dict(kwargs.pop("headers", None) or {})
    headers["X-Jarcut-Key"] = key
    try:
        async with httpx.AsyncClient(timeout=timeout, follow_redirects=True) as client:
            response = await client.request(method, base + path, headers=headers, **kwargs)
    except httpx.RequestError as exc:
        raise GpuError(
            f"Colab не отвечает ({type(exc).__name__}). Проверь, что ноутбук запущен, а ссылка в .env свежая.",
            "GPU_UNREACHABLE",
        ) from exc
    if response.status_code == 401:
        raise GpuError("Colab отклонил ключ — скопируй строку JARCUT_GPU_URL из ноутбука заново", "BAD_KEY", 401)
    if response.status_code in _TUNNEL_DOWN_STATUSES and "json" not in response.headers.get("content-type", ""):
        raise GpuError(
            f"Туннель к Colab не работает (HTTP {response.status_code}): ноутбук остановлен или ссылка устарела.",
            "GPU_UNREACHABLE", response.status_code,
        )
    return response


# Сколько всего ждать, пока на Colab грузится OmniVoice или видеокарта занята
# очисткой звука, прежде чем сдаться (очистка длинного видео идёт минутами).
GPU_WAIT_BUDGET_SECONDS = 20 * 60


async def gpu_post_with_retries(path: str, what: str, *, timeout: float, **kwargs: Any) -> httpx.Response:
    """POST на Colab с повторами:
      - туннель моргнул (GPU_UNREACHABLE) — до 3 попыток подряд;
      - OmniVoice ещё грузится (TTS_NOT_READY) или видеокарта занята очисткой
        (GPU_BUSY) — ждём по 10 с, всего не дольше GPU_WAIT_BUDGET_SECONDS.
    Любой другой ответ (в том числе ошибка) возвращается вызывающему.
    kwargs не должны содержать открытых файлов — только байты/JSON, чтобы
    запрос можно было повторить."""
    unreachable = 0
    started = time.monotonic()
    announced = ""
    while True:
        try:
            response = await gpu_request("POST", path, timeout=timeout, **kwargs)
        except GpuError as exc:
            if exc.code != "GPU_UNREACHABLE":
                raise
            unreachable += 1
            if unreachable >= 3:
                raise
            await asyncio.sleep(2.0 * unreachable)
            continue
        unreachable = 0
        if response.status_code != 200:
            message, code = _gpu_error_message(response)
            if code in ("TTS_NOT_READY", "GPU_BUSY") and time.monotonic() - started < GPU_WAIT_BUDGET_SECONDS:
                if announced != code:
                    reason = "видеокарта занята очисткой звука" if code == "GPU_BUSY" else "OmniVoice ещё загружается"
                    print(f"[voice] {what}: {reason} — жду (до {GPU_WAIT_BUDGET_SECONDS // 60} мин)", flush=True)
                    announced = code
                await asyncio.sleep(10)
                continue
        return response


async def gpu_download(path: str, target: Path, timeout: float = 900) -> None:
    """Скачивает файл с Colab потоком (дорожки длинного видео весят сотни МБ)."""
    endpoint = gpu_endpoint()
    if endpoint is None:
        raise GpuError("JARCUT_GPU_URL не задан в .env", "NO_GPU_URL")
    base, key = endpoint
    try:
        async with httpx.AsyncClient(timeout=timeout, follow_redirects=True) as client:
            async with client.stream("GET", base + path, headers={"X-Jarcut-Key": key}) as response:
                if response.status_code != 200:
                    await response.aread()
                    message, code = _gpu_error_message(response)
                    raise GpuError(f"Не удалось скачать {path} с Colab: {message}", code, response.status_code)
                with open(target, "wb") as handle:
                    async for chunk in response.aiter_bytes():
                        handle.write(chunk)
    except httpx.RequestError as exc:
        raise GpuError(f"Скачивание с Colab оборвалось ({type(exc).__name__})", "GPU_UNREACHABLE") from exc
    if not target.exists() or target.stat().st_size == 0:
        raise GpuError(f"С Colab пришёл пустой файл: {path}")


_gpu_version_cache: dict[str, Any] = {"base": None, "version": 1, "checked": 0.0}


async def gpu_version() -> int:
    """Версия ноутбука (поле version в /health). 1 = старый ноутбук."""
    endpoint = gpu_endpoint()
    base = endpoint[0] if endpoint else ""
    if _gpu_version_cache["base"] == base and time.monotonic() - _gpu_version_cache["checked"] < 60:
        return int(_gpu_version_cache["version"])
    response = await gpu_request("GET", "/health", timeout=20)
    try:
        version = int(str(response.json().get("version") or "1"))
    except Exception:
        version = 1
    _gpu_version_cache.update(base=base, version=version, checked=time.monotonic())
    return version


@app.get("/api/gpu/status")
async def gpu_status() -> dict[str, Any]:
    try:
        response = await gpu_request("GET", "/health", timeout=20)
    except GpuError as exc:
        return {"ok": False, "error": str(exc), "code": exc.code}
    if response.status_code != 200:
        message, code = _gpu_error_message(response)
        return {"ok": False, "error": message, "code": code}
    data = response.json()
    return {
        "ok": True, "tts": data.get("tts"), "ttsError": data.get("ttsError"), "gpu": data.get("gpu"),
        "version": data.get("version"), "busy": data.get("busy", ""),
    }


# ---- Шаг 0: очистка звука на Colab ----------------------------------------------

STEM_NAMES = ("vocals_raw", "vocals_clean", "background")
SEPARATION_MODEL_CHOICES = ("kim", "viperx")
# Бесплатный туннель Cloudflare не пропускает запрос больше 100 МБ. Файл
# больше этого порога уходит на Colab частями по UPLOAD_CHUNK_BYTES.
SINGLE_UPLOAD_LIMIT = 90 * 1024 * 1024
UPLOAD_CHUNK_BYTES = 40 * 1024 * 1024


def stems_meta_path(video: Path) -> Path:
    return UPLOADS / f"{video.stem}_stems.json"


def load_stems(video: Path) -> dict[str, Path] | None:
    """Готовые дорожки очистки для этого видео, если все файлы на месте:
    vocals_raw (голоса как есть после разделения — для смеха/реакций),
    vocals_clean (голос без эха и шума — для распознавания и референсов),
    background (всё, кроме голосов — для экспорта)."""
    meta_path = stems_meta_path(video)
    if not meta_path.exists():
        return None
    try:
        meta = json.loads(meta_path.read_text())
        paths = {name: UPLOADS / Path(meta["files"][name]).name for name in STEM_NAMES}
    except Exception:
        return None
    if all(path.exists() and path.stat().st_size > 0 for path in paths.values()):
        return paths
    return None


def separation_options(body: dict[str, Any]) -> dict[str, Any]:
    model = str(body.get("model") or "kim").strip().lower()
    return {
        "model": model if model in SEPARATION_MODEL_CHOICES else "kim",
        "dereverb": parse_bool(body.get("dereverb"), True),
        "denoise": parse_bool(body.get("denoise"), True),
        "aggressive": parse_bool(body.get("aggressive"), False),
    }


def extract_audio_for_separation(source: Path, work_dir: Path) -> Path | None:
    """Звук видео для отправки на Colab: FLAC 44.1 кГц стерео — без потерь,
    модели разделения лучше работают с несжатым звуком. Если FLAC выходит
    больше ~90 МБ (длинное видео), берётся MP3 320k, чтобы не грузить сотни
    мегабайт. Файл больше 90 МБ уходит на Colab частями (см. upload_in_parts),
    поэтому длина видео больше не ограничена ~40 минутами."""
    flac = work_dir / "source.flac"
    command = ["ffmpeg", "-y", "-i", str(source), "-vn", "-ac", "2", "-ar", "44100", "-c:a", "flac", str(flac)]
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=1800)
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return None
    if result.returncode == 0 and flac.exists() and 0 < flac.stat().st_size <= SINGLE_UPLOAD_LIMIT:
        return flac

    mp3 = work_dir / "source.mp3"
    command = ["ffmpeg", "-y", "-i", str(source), "-vn", "-ac", "2", "-ar", "44100",
               "-c:a", "libmp3lame", "-b:a", "320k", str(mp3)]
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=1800)
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return None
    flac.unlink(missing_ok=True)
    if result.returncode == 0 and mp3.exists() and mp3.stat().st_size > 0:
        print(f"[clean] Видео длинное — отправляю MP3 320k вместо FLAC ({mp3.stat().st_size / 1024 / 1024:.0f} МБ)", flush=True)
        return mp3
    return None


def _read_chunk(path: Path, offset: int, size: int) -> bytes:
    with open(path, "rb") as handle:
        handle.seek(offset)
        return handle.read(size)


async def upload_in_parts(audio: Path) -> str:
    """Загружает большой файл на Colab кусками по 40 МБ (каждый запрос меньше
    лимита туннеля в 100 МБ). Возвращает upload_id для /separate.
    Кусок, на котором туннель моргнул, отправляется заново с того же места."""
    if await gpu_version() < 2:
        raise GpuError(
            "Звук этого видео больше 90 МБ, а Colab-ноутбук старой версии и не умеет принимать файл частями. "
            "Открой новый JarCut_GPU.ipynb, «Выполнить всё» и вставь новую строку JARCUT_GPU_URL в .env.",
            "GPU_TOO_OLD",
        )
    response = await gpu_request("POST", "/uploads", timeout=60)
    if response.status_code != 200:
        message, code = _gpu_error_message(response)
        raise GpuError(f"Colab не начал приём файла: {message}", code, response.status_code)
    upload_id = str(response.json()["upload_id"])

    total = audio.stat().st_size
    offset = 0
    while offset < total:
        chunk = await asyncio.to_thread(_read_chunk, audio, offset, UPLOAD_CHUNK_BYTES)
        for attempt in range(1, 5):
            try:
                response = await gpu_request(
                    "PUT", f"/uploads/{upload_id}?offset={offset}", timeout=900,
                    content=chunk, headers={"Content-Type": "application/octet-stream"},
                )
            except GpuError as exc:
                if exc.code != "GPU_UNREACHABLE" or attempt == 4:
                    raise
                await asyncio.sleep(3.0 * attempt)
                continue
            if response.status_code != 200:
                message, code = _gpu_error_message(response)
                raise GpuError(f"Colab не принял часть файла: {message}", code, response.status_code)
            break
        offset += len(chunk)
        print(f"[clean] Загружено на Colab {offset / 1024 / 1024:.0f} из {total / 1024 / 1024:.0f} МБ", flush=True)
    return upload_id


async def run_gpu_separation(audio: Path, options: dict[str, Any], stem: str) -> dict[str, Path]:
    """Отправляет звук на Colab, ждёт окончания очистки и скачивает три дорожки.

    Очистка идёт на Colab как фоновая задача: туннель Cloudflare обрывает
    запросы длиннее ~100 секунд, а разделение длинного видео идёт дольше.
    Поэтому тут: отправить -> опрашивать статус каждые 3 с -> скачать."""
    mime = "audio/flac" if audio.suffix == ".flac" else "audio/mpeg"
    form = {key: ("1" if value is True else "0" if value is False else str(value)) for key, value in options.items()}
    if audio.stat().st_size > SINGLE_UPLOAD_LIMIT:
        upload_id = await upload_in_parts(audio)
        response = await gpu_request("POST", "/separate", timeout=600, data={**form, "upload_id": upload_id, "filename": audio.name})
    else:
        with open(audio, "rb") as handle:
            response = await gpu_request("POST", "/separate", timeout=1800, files={"file": (audio.name, handle, mime)}, data=form)
    if response.status_code != 200:
        message, code = _gpu_error_message(response)
        raise GpuError(f"Colab не принял звук: {message}", code, response.status_code)
    job_id = response.json()["job_id"]

    deadline = time.monotonic() + 3 * 3600
    last_step = ""
    failures = 0
    while True:
        await asyncio.sleep(3)
        if time.monotonic() > deadline:
            raise GpuError("Очистка идёт дольше 3 часов — прервано", "GPU_TIMEOUT")
        try:
            status_response = await gpu_request("GET", f"/jobs/{job_id}", timeout=30)
        except GpuError:
            failures += 1  # туннель иногда моргает — несколько промахов подряд терпим
            if failures >= 10:
                raise
            continue
        failures = 0
        if status_response.status_code != 200:
            message, code = _gpu_error_message(status_response)
            raise GpuError(f"Colab потерял задачу очистки: {message}", code)
        job = status_response.json()
        step = str(job.get("step") or "")
        if step and step != last_step:
            print(f"[clean] Colab: {step} ({float(job.get('elapsed') or 0):.0f} с)", flush=True)
            last_step = step
        if job.get("status") == "done":
            break
        if job.get("status") == "error":
            raise GpuError(f"Очистка на Colab упала: {job.get('error')}", "GPU_JOB_FAILED")

    paths: dict[str, Path] = {}
    for name in STEM_NAMES:
        target = UPLOADS / f"{stem}_{name}.flac"
        await gpu_download(f"/files/{job_id}/{name}", target)
        paths[name] = target
    try:
        await gpu_request("DELETE", f"/jobs/{job_id}", timeout=30)
    except GpuError:
        pass  # не страшно: всё сотрётся при перезапуске Colab
    return paths


@app.post("/api/prepare")
async def prepare(request: Request) -> dict[str, Any]:
    """Шаг 0: очистка звука на Colab — голос отдельно, фон отдельно.

    Результат кэшируется рядом с видео: повторный вызов с теми же настройками
    ничего не отправляет на Colab. Другие настройки — очистка заново."""
    body = await request.json()
    source = UPLOADS / Path(str(body.get("filename") or "")).name
    if not source.exists() or not source.is_file():
        raise HTTPException(404, "Файл не найден")
    options = separation_options(body)
    force = parse_bool(body.get("force"), False)

    meta_path = stems_meta_path(source)
    existing = load_stems(source)
    if existing and not force:
        try:
            if json.loads(meta_path.read_text()).get("options") == options:
                return {"ok": True, "cached": True, "files": {name: f"/uploads/{path.name}" for name, path in existing.items()}}
        except Exception:
            pass

    if not await asyncio.to_thread(has_audio_stream, source):
        return {"ok": False, "error": "В видео нет звуковой дорожки"}

    started = time.monotonic()
    try:
        with tempfile.TemporaryDirectory(prefix="jarcut2_sep_") as work_dir:
            audio = await asyncio.to_thread(extract_audio_for_separation, source, Path(work_dir))
            if audio is None:
                return {"ok": False, "error": "Не удалось извлечь звук из видео (проверьте ffmpeg)"}
            print(f"[clean] Отправляю звук на Colab ({audio.stat().st_size / 1024 / 1024:.1f} МБ), настройки: {options}", flush=True)
            paths = await run_gpu_separation(audio, options, source.stem)
    except GpuError as exc:
        print(f"[clean] Ошибка: {exc}", flush=True)
        return {"ok": False, "error": str(exc), "code": exc.code}

    meta_path.write_text(json.dumps({"options": options, "files": {name: path.name for name, path in paths.items()}}, ensure_ascii=False))
    seconds = time.monotonic() - started
    print(f"[clean] Готово за {seconds:.0f} с", flush=True)
    return {"ok": True, "cached": False, "seconds": round(seconds, 1),
            "files": {name: f"/uploads/{path.name}" for name, path in paths.items()}}


# ---- Референсы для клонирования --------------------------------------------------


def reference_audio_source(video: Path, ref_source: str = "clean") -> Path:
    """Откуда резать референсы. clean — голос после очистки (без музыки, эха и
    шума); raw — голос сразу после отделения от музыки, без шумодава и
    удаления эха (см. OMNIVOICE_REF_SOURCE). Без очистки — звук самого видео."""
    stems = load_stems(video)
    if not stems:
        return video
    return stems["vocals_raw"] if ref_source == "raw" else stems["vocals_clean"]


def _seg_speaker(segment: dict[str, Any]) -> str:
    return str(segment.get("speaker_id") or "S1")


def _seg_bounds(segment: dict[str, Any]) -> tuple[float, float]:
    start = float(segment.get("start") or 0)
    end = float(segment.get("end") or start)
    return start, max(start, end)


def padded_bounds(context: list[dict[str, Any]], index: int, pad: float = REF_PAD_SECONDS) -> tuple[float, float]:
    """Границы реплики с небольшим запасом, но не залезая на соседние реплики."""
    start, end = _seg_bounds(context[index])
    low, high = max(0.0, start - pad), end + pad
    for other_index, other in enumerate(context):
        if other_index == index:
            continue
        other_start, other_end = _seg_bounds(other)
        if other_end <= start:
            low = max(low, other_end)
        elif other_start >= end:
            high = min(high, other_start)
    return low, max(low + 0.05, high)


def choose_reference_indices(
    context: list[dict[str, Any]], index: int, mode: str = "auto", target: float = 6.0
) -> tuple[list[int], str]:
    """Какие реплики того же спикера пойдут в референс для реплики index.

      line      — реплика длиной от target до 10 с: клон из неё самой
                  (точнее всего передаёт интонацию именно этого момента);
      neighbors — реплика короче target: она сама + ближайшие ПО ВРЕМЕНИ
                  реплики того же спикера (не дальше REF_NEIGHBOR_WINDOW_SECONDS),
                  пока не наберётся target секунд. Сама реплика ставится
                  последней: OmniVoice продолжает речь сразу после референса,
                  поэтому ближе всего к дубляжу звучит её собственная интонация;
      speaker   — реплика длиннее 10 с, соседей мало или mode="speaker":
                  лучшие (самые длинные) куски этого спикера по всему видео.
    Раньше «соседи» искались по номеру реплики без ограничения по времени
    и могли прийти из другого конца видео, а референс в 3 с считался
    достаточным — короткий референс даёт заметно менее похожий тембр.
    """
    speaker = _seg_speaker(context[index])

    def duration(i: int) -> float:
        start, end = _seg_bounds(context[i])
        return end - start

    def start_of(i: int) -> float:
        return _seg_bounds(context[i])[0]

    own = duration(index)
    if mode != "speaker":
        if target <= own <= REF_LINE_MAX_SECONDS:
            return [index], "line"
        if own < target:
            include_self = own >= 0.3
            total = own if include_self else 0.0
            here = start_of(index)
            nearby = [
                i for i in range(len(context))
                if i != index
                and _seg_speaker(context[i]) == speaker
                and 0.3 <= duration(i) <= REF_LINE_MAX_SECONDS
                and abs(start_of(i) - here) <= REF_NEIGHBOR_WINDOW_SECONDS
            ]
            nearby.sort(key=lambda i: abs(start_of(i) - here))
            picked: list[int] = []
            for i in nearby:
                if total >= target:
                    break
                if total + duration(i) > REF_MAX_TOTAL_SECONDS:
                    continue
                picked.append(i)
                total += duration(i)
            if total >= REF_LINE_MIN_SECONDS:
                order = sorted(picked) + ([index] if include_self else [])
                return order, ("neighbors" if picked else "line")

    candidates = [
        i for i in range(len(context))
        if _seg_speaker(context[i]) == speaker and 0.8 <= duration(i) <= REF_LINE_MAX_SECONDS
    ]
    candidates.sort(key=duration, reverse=True)
    picked, total = [], 0.0
    for i in candidates:
        if total + duration(i) > REF_MAX_TOTAL_SECONDS:
            continue
        picked.append(i)
        total += duration(i)
        if total >= target:
            break
    if picked:
        return sorted(picked), "speaker"

    # У спикера одни очень короткие реплики («Э!», «Да») — берём что есть.
    picked, total = [], 0.0
    for i in range(len(context)):
        if _seg_speaker(context[i]) == speaker and duration(i) >= 0.1 and total + duration(i) <= REF_MAX_TOTAL_SECONDS:
            picked.append(i)
            total += duration(i)
    if picked and total >= 1.0:
        return picked, "speaker-short"
    return [index], "line"


def build_reference(
    source: Path, context: list[dict[str, Any]], indices: list[int], refs_dir: Path
) -> tuple[Path, str] | None:
    """Вырезает куски (в порядке indices), склеивает их и возвращает
    (файл, точный текст референса).

    Текст берётся из распознавания Scribe (поле original): с ним OmniVoice не
    распознаёт референс сам своим Whisper — быстрее и без его ошибок.
    Куски кэшируются на диске, повторная озвучка их не режет заново."""
    try:
        stamp = source.stat().st_mtime_ns
    except OSError:
        return None

    pieces: list[Path] = []
    texts: list[str] = []
    for i in indices:
        start, end = padded_bounds(context, i)
        digest = hashlib.sha1(f"{source.name}|{stamp}|{start:.3f}|{end:.3f}".encode()).hexdigest()[:16]
        piece = refs_dir / f"piece_{digest}.wav"
        if not (piece.exists() and piece.stat().st_size > 44):
            if not extract_segment_wav(source, start, end, piece):
                continue
        pieces.append(piece)
        texts.append(str(context[i].get("original") or "").strip())

    if not pieces:
        return None
    ref_text = " ".join(text for text in texts if text)
    if len(pieces) == 1:
        return pieces[0], ref_text

    digest = hashlib.sha1("|".join(piece.name for piece in pieces).encode()).hexdigest()[:16]
    combined = refs_dir / f"ref_{digest}.wav"
    if not (combined.exists() and combined.stat().st_size > 44):
        if concat_audio_clips(pieces, combined, refs_dir, tag=digest) is None:
            return pieces[0], texts[0]
    return combined, ref_text


def available_slot(context: list[dict[str, Any]], index: int) -> float | None:
    """Сколько секунд есть у дубляжа реплики: до начала следующей реплики
    (любого спикера), но не меньше её собственной длины. None — реплика
    последняя, ей ничто не мешает. Та же логика, что в plan_dub_placement."""
    start, end = _seg_bounds(context[index])
    later = [
        _seg_bounds(other)[0] for i, other in enumerate(context)
        if i != index and _seg_bounds(other)[0] > start + 0.01
    ]
    if not later:
        return None
    return max(0.2, end - start, min(later) - start)


# ---- Озвучка ---------------------------------------------------------------------

# Голоса, уже отправленные на Colab: (адрес Colab, ключ). После перезапуска
# Colab адрес другой, поэтому голоса автоматически отправятся заново.
_registered_voices: set[tuple[str, str]] = set()


async def gpu_register_voice(ref_path: Path, ref_text: str, force: bool = False) -> str:
    """Отправляет референс на Colab один раз; Colab кодирует голос и помнит его
    под ключом (хэш звука + текста). Все следующие реплики с тем же
    референсом идут без повторной загрузки и кодирования."""
    data = await asyncio.to_thread(ref_path.read_bytes)
    key = hashlib.sha1(data + b"\x00" + ref_text.encode("utf-8")).hexdigest()[:24]
    endpoint = gpu_endpoint()
    base = endpoint[0] if endpoint else ""
    if not force and (base, key) in _registered_voices:
        return key
    response = await gpu_post_with_retries(
        "/voices", "голос", timeout=180,
        files={"file": (ref_path.name, data, "audio/wav")}, data={"key": key, "ref_text": ref_text},
    )
    if response.status_code != 200:
        message, code = _gpu_error_message(response)
        raise GpuError(f"Colab не смог подготовить голос: {message}", code, response.status_code)
    _registered_voices.add((base, key))
    return key


async def gpu_tts(
    text: str, language_name: str, ref_path: Path, ref_text: str,
    settings: dict[str, Any], duration: float | None = None,
) -> bytes:
    payload: dict[str, Any] = {
        "text": text,
        "language": language_name or None,
        "voice_key": await gpu_register_voice(ref_path, ref_text),
        "num_step": settings["num_step"],
        "guidance_scale": settings["guidance_scale"],
        "speed": settings["speed"],
        "denoise": settings["denoise"],
    }
    if duration and duration > 0:
        payload["duration"] = round(duration, 3)
    last_error: GpuError | None = None
    for reregistered in (False, True):
        response = await gpu_post_with_retries("/tts", "озвучка", timeout=300, json=payload)
        if response.status_code == 200 and response.content:
            return response.content
        message, code = _gpu_error_message(response)
        last_error = GpuError(f"OmniVoice на Colab: {message}", code, response.status_code)
        if code == "VOICE_NOT_FOUND" and not reregistered:
            # Colab перезапускали (или он вытеснил старый голос) — отправляем
            # голос заново и ПОВТОРЯЕМ озвучку с новым ключом. Раньше при
            # такой ошибке на последней попытке реплика падала, хотя голос
            # уже был перерегистрирован.
            payload["voice_key"] = await gpu_register_voice(ref_path, ref_text, force=True)
            continue
        raise last_error
    raise last_error or GpuError("OmniVoice на Colab не ответил")


def store_voice_clip(audio_bytes: bytes) -> Path:
    """Сохраняет ответ OmniVoice и срезает длинную тишину по краям до
    EDGE_SILENCE_KEEP_SECONDS. Если анализ не удался — файл как есть."""
    out_path = UPLOADS / f"voice_{uuid.uuid4().hex[:10]}.wav"
    out_path.write_bytes(audio_bytes)
    trimmed_path = UPLOADS / f"voice_{uuid.uuid4().hex[:10]}.wav"
    if trim_edge_silence(out_path, trimmed_path):
        out_path.unlink(missing_ok=True)
        return trimmed_path
    trimmed_path.unlink(missing_ok=True)
    return out_path


def measure_voice_length(path: Path) -> float:
    """Длина звучащей части клипа (без тишины по краям), как в plan_dub_placement."""
    total, lead, tail = analyze_clip(path)
    voice = total - lead - tail
    return voice if voice > 0.05 else total


async def synthesize_line(
    text: str, ref_path: Path, ref_text: str, target_duration: float, language_name: str,
    settings: dict[str, Any], slot: float | None = None,
) -> dict[str, Any]:
    audio_bytes = await gpu_tts(text, language_name, ref_path, ref_text, settings)
    out_path = await asyncio.to_thread(store_voice_clip, audio_bytes)

    # Подгонка под длину. Если голос не влезает до начала следующей реплики,
    # раньше экспорт ускорял его через atempo (до 1.3x) — atempo заметно
    # портит голос («фазовый», металлический звук). Теперь OmniVoice сразу
    # генерирует реплику нужной длины (параметр duration): модель сама
    # говорит быстрее, и звук остаётся чистым. Сильнее fit_max_speedup не
    # сжимаем — дальше речь становится неразборчивой; остаток экспорт
    # покажет как наложение.
    natural_voice: float | None = None
    fitted = False
    if settings["fit_duration"] and slot:
        voice_length = await asyncio.to_thread(measure_voice_length, out_path)
        if voice_length > slot * 1.05:
            natural_voice = round(voice_length, 3)
            wanted = max(slot, voice_length / settings["fit_max_speedup"])
            try:
                fitted_bytes = await gpu_tts(text, language_name, ref_path, ref_text, settings, duration=wanted)
                fitted_path = await asyncio.to_thread(store_voice_clip, fitted_bytes)
                out_path.unlink(missing_ok=True)
                out_path = fitted_path
                fitted = True
                print(f"[voice] реплика {voice_length:.2f} с не влезала в {slot:.2f} с — сгенерирована сразу на {wanted:.2f} с", flush=True)
            except GpuError as exc:
                print(f"[voice] подгонка длины не удалась ({exc}) — оставляю обычную версию", flush=True)

    return {
        "ok": True,
        "filename": out_path.name,
        "url": f"/uploads/{out_path.name}",
        "audioDuration": round(await asyncio.to_thread(probe_duration, out_path), 3),
        "targetDuration": round(target_duration, 3),
        "method": "omnivoice-colab",
        "fitted": fitted,
        "naturalVoiceSeconds": natural_voice,
        "slotSeconds": round(slot, 3) if slot else None,
    }


@app.post("/api/voice")
async def voice(request: Request) -> dict[str, Any]:
    """Озвучивает присланные реплики (segments) клоном голоса их спикера.

    context — ВСЕ реплики видео (id, speaker_id, start, end, original).
    Без него короткой реплике не из чего собрать референс, и не видно, где
    начинается следующая реплика (нужно для подгонки длины)."""
    body = await request.json()
    language_code = str(body.get("languageCode") or "uz").strip().lower()
    if language_code not in LANGS:
        language_code = "uz"
    target_language = LANGS[language_code]
    omnivoice_language = OMNIVOICE_LANG_OVERRIDES.get(target_language, target_language)
    settings = omnivoice_settings()

    segments = [item for item in (body.get("segments") or []) if isinstance(item, dict)]
    context = [dict(item) for item in (body.get("context") or segments) if isinstance(item, dict)]
    index_by_id = {str(item.get("id")): i for i, item in enumerate(context)}

    video = UPLOADS / Path(str(body.get("video") or "")).name
    if not video.exists() or not video.is_file():
        error = "Видео не найдено на сервере — загрузите его заново"
        return {"ok": True, "results": [{"id": item.get("id"), "ok": False, "error": error} for item in segments]}
    ref_source = await asyncio.to_thread(reference_audio_source, video, settings["ref_source"])
    refs_dir = UPLOADS / f"{video.stem}_refs"
    refs_dir.mkdir(exist_ok=True)

    output: list[dict[str, Any]] = []
    for segment in segments:
        segment_id = segment.get("id")
        text = str(segment.get("text") or segment.get("translated") or "").strip()
        if not text:
            output.append({"id": segment_id, "ok": False, "error": "Пустой текст"})
            continue

        index = index_by_id.get(str(segment_id))
        if index is None:
            context.append(dict(segment))
            index = len(context) - 1
            index_by_id[str(segment_id)] = index
        else:
            # Спикера могли только что переназначить вручную — верим реплике.
            for key in ("speaker_id", "start", "end", "original"):
                if segment.get(key) not in (None, ""):
                    context[index][key] = segment[key]

        start, end = _seg_bounds(context[index])
        try:
            target_duration = float(segment.get("duration") or max(0.3, end - start))
        except (TypeError, ValueError):
            target_duration = max(0.3, end - start)
        indices, ref_kind = choose_reference_indices(context, index, settings["ref_mode"], settings["ref_target"])
        reference = await asyncio.to_thread(build_reference, ref_source, context, indices, refs_dir)
        if reference is None:
            output.append({"id": segment_id, "ok": False, "error": "Не удалось вырезать референс голоса из видео"})
            continue
        ref_path, ref_text = reference

        try:
            result = await synthesize_line(
                text, ref_path, ref_text, target_duration, omnivoice_language, settings,
                slot=available_slot(context, index),
            )
        except GpuError as exc:
            print(f"[voice] {segment_id}: {exc}", flush=True)
            result = {"ok": False, "error": str(exc)}
        result["id"] = segment_id
        result["refKind"] = ref_kind
        result["refSeconds"] = round(await asyncio.to_thread(probe_duration, ref_path), 2)
        output.append(result)

    return {"ok": True, "results": output}


# ---------------------------------------------------------------------------
# Step 4: ffmpeg — сборка финального видео
# ---------------------------------------------------------------------------


def atempo_chain(factor: float) -> str:
    factors: list[float] = []
    factor = max(0.5, min(factor, 2.0))
    factors.append(factor)
    return ",".join(f"atempo={item:.5f}" for item in factors)


def has_audio_stream(path: Path) -> bool:
    try:
        result = subprocess.run(
            ["ffprobe", "-v", "error", "-select_streams", "a:0", "-show_entries", "stream=index", "-of", "csv=p=0", str(path)],
            capture_output=True, text=True, timeout=30,
        )
        return result.returncode == 0 and bool(result.stdout.strip())
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return False


def has_video_stream(path: Path) -> bool:
    """Есть ли настоящая видеодорожка (обложка MP3 не считается)."""
    try:
        result = subprocess.run(
            ["ffprobe", "-v", "error", "-select_streams", "v", "-show_entries",
             "stream=index:stream_disposition=attached_pic", "-of", "json", str(path)],
            capture_output=True, text=True, timeout=30,
        )
        if result.returncode != 0:
            return False
        streams = json.loads(result.stdout or "{}").get("streams") or []
        return any(not (stream.get("disposition") or {}).get("attached_pic") for stream in streams)
    except (FileNotFoundError, subprocess.TimeoutExpired, ValueError):
        return False


def _gain_envelope_points(regions: list[tuple[float, float]], fade: float) -> tuple["np.ndarray", "np.ndarray"]:
    """Точки огибающей: 1 внутри regions, 0 снаружи, с линейными переходами
    длиной fade. Пересекающиеся области сливаются, поэтому x строго растут."""
    expanded = sorted((a - fade, b + fade) for a, b in regions if b > a)
    merged: list[list[float]] = []
    for a, b in expanded:
        if merged and a <= merged[-1][1]:
            merged[-1][1] = max(merged[-1][1], b)
        else:
            merged.append([a, b])
    xs: list[float] = []
    ys: list[float] = []
    for a, b in merged:
        xs += [a, a + fade, b - fade, b]
        ys += [0.0, 1.0, 1.0, 0.0]
    return np.array(xs, dtype=np.float64), np.array(ys, dtype=np.float64)


def apply_gain_regions(
    source: Path,
    target: Path,
    regions: list[tuple[float, float]],
    inside_gain: float,
    outside_gain: float = 1.0,
    fade: float = FADE_SECONDS,
    sample_rate: int = 44100,
) -> bool:
    """Пишет в target звук source (стерео FLAC), где громкость внутри regions
    равна inside_gain, а снаружи — outside_gain, с плавными переходами.

    Так сделаны обе вещи экспорта: приглушение фона под репликами и
    выключение голосов оригинала там, где звучит дубляж. Звук идёт кусками
    по 10 секунд, поэтому длинное видео не занимает гигабайты памяти."""
    xs, ys = _gain_envelope_points(regions, fade)
    channels = 2
    frame_bytes = 4 * channels
    decode = subprocess.Popen(
        ["ffmpeg", "-v", "error", "-i", str(source), "-vn", "-f", "f32le", "-ac", str(channels), "-ar", str(sample_rate), "-"],
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
    )
    encode = subprocess.Popen(
        ["ffmpeg", "-v", "error", "-y", "-f", "f32le", "-ac", str(channels), "-ar", str(sample_rate), "-i", "-",
         "-c:a", "flac", str(target)],
        stdin=subprocess.PIPE, stderr=subprocess.DEVNULL,
    )
    position = 0
    leftover = b""
    try:
        while True:
            chunk = decode.stdout.read(sample_rate * 10 * frame_bytes)
            if not chunk:
                break
            chunk = leftover + chunk
            usable = len(chunk) - len(chunk) % frame_bytes
            leftover = chunk[usable:]
            if usable == 0:
                continue
            samples = np.frombuffer(chunk[:usable], dtype=np.float32).reshape(-1, channels)
            times = (position + np.arange(samples.shape[0])) / sample_rate
            weight = np.interp(times, xs, ys, left=0.0, right=0.0) if xs.size else np.zeros(samples.shape[0])
            gain = (outside_gain + (inside_gain - outside_gain) * weight).astype(np.float32)
            encode.stdin.write((samples * gain[:, None]).astype(np.float32).tobytes())
            position += samples.shape[0]
        encode.stdin.close()
        decode.wait(timeout=120)
        encode.wait(timeout=900)
    except Exception as exc:
        print(f"[export] Не удалось обработать {source.name}: {exc}", flush=True)
        for process in (decode, encode):
            try:
                process.kill()
            except Exception:
                pass
        return False
    return decode.returncode == 0 and encode.returncode == 0 and target.exists() and target.stat().st_size > 0


def plan_dub_placement(valid_segments: list[tuple[dict[str, Any], Path]]) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    """Где в итоговом видео звучит каждая реплика дубляжа.

    - Сдвиг offsetMs применяется до сортировки и расчёта свободного места.
    - Реплика ускоряется (до 1.3x), только если её голос не влезает до начала
      следующей. Тишина в начале и в конце клипа в длину голоса не считается.
      (Обычно этого уже не нужно: /api/voice сам генерирует не влезающую
      реплику нужной длины — см. synthesize_line.)
    - Тишина в начале клипа не задерживает голос: клип ставится раньше
      ровно на неё, поэтому голос начинается вовремя.
    - Если голос не влезает даже на 1.3x, реплика попадает в warnings: она
      наложится на следующую, и её стоит сократить."""

    def shifted_start(segment: dict[str, Any]) -> float:
        base = max(0.0, float(segment.get("start", 0) or 0))
        return max(0.0, base + float(segment.get("offsetMs", 0) or 0) / 1000.0)

    ordered = sorted(range(len(valid_segments)), key=lambda i: shifted_start(valid_segments[i][0]))
    # Все клипы анализируются параллельно и по одному разу.
    unique_clips = sorted({audio for _segment, audio in valid_segments})
    with ThreadPoolExecutor(max_workers=8) as pool:
        clip_info = dict(zip(unique_clips, pool.map(analyze_clip, unique_clips)))
    specs: list[dict[str, Any]] = []
    warnings: list[dict[str, Any]] = []
    for position, segment_index in enumerate(ordered):
        segment, audio = valid_segments[segment_index]
        start = shifted_start(segment)
        offset = float(segment.get("offsetMs", 0) or 0) / 1000.0
        base_start = max(0.0, float(segment.get("start", 0) or 0))
        raw_end = segment.get("end")
        base_end = float(raw_end) if raw_end not in (None, "") else base_start + 2.0
        shifted_end = max(start, base_end + offset)
        own_slot = max(0.2, shifted_end - start)
        next_start = shifted_start(valid_segments[ordered[position + 1]][0]) if position + 1 < len(ordered) else None
        available = max(own_slot, next_start - start) if next_start is not None else own_slot

        clip_duration, lead, tail = clip_info[audio]
        voice_length = clip_duration - lead - tail
        if voice_length <= 0.05:
            voice_length, lead, tail = clip_duration, 0.0, 0.0
        speed = min(1.3, max(1.0, voice_length / available)) if voice_length > 0 else 1.0

        placed = max(0.0, start - max(0.0, lead - 0.03) / speed)
        voice_start = placed + lead / speed
        voice_end = voice_start + voice_length / speed
        clip_end = placed + max(0.0, clip_duration - tail) / speed

        if next_start is not None and voice_end > next_start + 0.05:
            warnings.append({"id": segment.get("id"), "overlapSeconds": round(voice_end - next_start, 2)})

        original_start = base_start
        original_end = max(original_start, base_end)
        specs.append({
            "segment_index": segment_index,
            "placed": placed,
            "speed": speed,
            "voice_start": voice_start,
            "voice_end": voice_end,
            "clip_end": clip_end,
            "original_start": original_start,
            "original_end": original_end,
        })
    return specs, warnings


def decode_clip(path: Path, speed: float, sample_rate: int) -> "np.ndarray | None":
    """Клип дубляжа -> моно float32 с нужной частотой (и ускорением atempo)."""
    command = ["ffmpeg", "-v", "error", "-i", str(path)]
    if speed > 1.0005:
        command += ["-af", atempo_chain(speed)]
    command += ["-f", "f32le", "-ac", "1", "-ar", str(sample_rate), "-"]
    try:
        result = subprocess.run(command, capture_output=True, timeout=120)
    except (OSError, subprocess.TimeoutExpired):
        return None
    usable = (len(result.stdout) // 4) * 4
    if result.returncode != 0 or usable == 0:
        return None
    return np.frombuffer(result.stdout[:usable], dtype=np.float32)


def render_dub_track(
    specs: list[dict[str, Any]],
    valid_segments: list[tuple[dict[str, Any], Path]],
    total_duration: float,
    target: Path,
    sample_rate: int = 44100,
) -> tuple[bool, list[Any]]:
    """Собирает ВСЕ реплики дубляжа в одну моно-дорожку (FLAC).

    Раньше каждая реплика шла в ffmpeg отдельным входом (-i) со своим
    фильтром. На 350 репликах команда занимала ~51 000 символов — больше
    лимита Windows (32 767), и экспорт падал; на Linux тот же предел
    наступал около 1000 реплик (лимит открытых файлов). Теперь реплики
    раскладываются по местам здесь, в numpy, а ffmpeg получает 2–4 входа
    при любом числе реплик. Дорожка лежит на диске (memmap), а не в памяти.
    Возвращает (успех, id реплик, которые не удалось прочитать)."""
    frames = int(math.ceil(total_duration * sample_rate)) + sample_rate
    raw_path = target.with_suffix(".f32")
    track = np.memmap(raw_path, dtype=np.float32, mode="w+", shape=(frames,))
    skipped: list[Any] = []
    jobs = [(spec, valid_segments[spec["segment_index"]]) for spec in specs]
    with ThreadPoolExecutor(max_workers=4) as pool:
        for batch_start in range(0, len(jobs), 16):
            batch = jobs[batch_start:batch_start + 16]
            decoded = list(pool.map(lambda job: decode_clip(job[1][1], job[0]["speed"], sample_rate), batch))
            for (spec, (segment, audio)), samples in zip(batch, decoded):
                if samples is None or samples.size == 0:
                    print(f"[export] Не удалось прочитать {audio.name} — реплика пропущена", flush=True)
                    skipped.append(segment.get("id"))
                    continue
                begin = int(round(spec["placed"] * sample_rate))
                if begin >= frames:
                    continue
                stop = min(frames, begin + samples.size)
                track[begin:stop] += samples[: stop - begin]
    track.flush()
    del track
    try:
        result = subprocess.run(
            ["ffmpeg", "-v", "error", "-y", "-f", "f32le", "-ac", "1", "-ar", str(sample_rate),
             "-i", str(raw_path), "-c:a", "flac", str(target)],
            capture_output=True, text=True, timeout=1800,
        )
        ok = result.returncode == 0 and target.exists() and target.stat().st_size > 0
        if not ok:
            print(f"[export] Не удалось записать дорожку дубляжа: {result.stderr[-300:]}", flush=True)
    except (OSError, subprocess.TimeoutExpired) as exc:
        print(f"[export] Не удалось записать дорожку дубляжа: {exc}", flush=True)
        ok = False
    finally:
        raw_path.unlink(missing_ok=True)
    return ok, skipped


@app.post("/api/export")
async def export(request: Request) -> dict[str, Any]:
    """Сборка видео: дубляж + звук оригинала.

    Если для видео делалась очистка (шаг 0):
      - фон берётся из дорожки background (музыка и звуки без голосов) и
        приглушается под каждой репликой дубляжа;
      - keepReactions: дорожка голосов оригинала звучит в паузах между
        репликами (смех, крики, реакции) и выключается там, где звучит дубляж
        или где говорил переведённый спикер.
    Без очистки — как раньше: звук оригинала целиком (голоса тоже), тоже с
    приглушением под репликами.
    Если загружен аудиофайл без видео — результат будет .m4a."""
    body = await request.json()
    video = UPLOADS / Path(str(body.get("video") or "")).name
    segments = body.get("segments") or []
    try:
        volume = float(body.get("backgroundVolume", body.get("originalVolume", 0.85)) or 0)
    except (TypeError, ValueError):
        volume = 0.85
    volume = max(0.0, min(volume, 1.5))
    keep_reactions = parse_bool(body.get("keepReactions"), True)
    use_stems = parse_bool(body.get("useStems"), True)
    if not video.exists() or not video.is_file():
        raise HTTPException(404, "Видео не найдено")

    valid_segments: list[tuple[dict[str, Any], Path]] = []
    for segment in segments:
        if not isinstance(segment, dict):
            continue
        audio = UPLOADS / Path(str(segment.get("audio") or "")).name
        if audio.exists() and audio.is_file():
            valid_segments.append((segment, audio))
    if not valid_segments:
        raise HTTPException(400, "Нет готовых реплик для экспорта")

    video_duration = await asyncio.to_thread(probe_duration, video)
    if video_duration <= 0:
        return {"ok": False, "error": "ffprobe не смог определить длительность видео"}

    stems = await asyncio.to_thread(load_stems, video) if use_stems else None
    video_has_audio = await asyncio.to_thread(has_audio_stream, video)
    video_has_picture = await asyncio.to_thread(has_video_stream, video)
    specs, warnings = await asyncio.to_thread(plan_dub_placement, valid_segments)
    output_duration = max([video_duration] + [spec["clip_end"] for spec in specs])

    duck_regions = [(spec["voice_start"], spec["voice_end"]) for spec in specs]
    # Голоса оригинала молчат и там, где звучит дубляж, и там, где говорил
    # сам переведённый спикер (даже если дубляж короче оригинала).
    mute_regions = [
        (min(spec["original_start"], spec["voice_start"]) - 0.12, max(spec["original_end"], spec["voice_end"]) + 0.12)
        for spec in specs
    ]

    # Все входы приводятся к 44.1 кГц стерео явно, а не как решит amix.
    stereo = "aformat=sample_rates=44100:channel_layouts=stereo"
    with tempfile.TemporaryDirectory(prefix="jarcut2_export_") as temp_dir:
        work = Path(temp_dir)
        inputs = ["-i", str(video)]
        filters: list[str] = []
        mix_labels: list[str] = []
        next_input = 1
        duration_str = f"{output_duration:.3f}"

        background_source = stems["background"] if stems else (video if video_has_audio else None)
        if background_source is not None:
            ducked = work / "background.flac"
            if await asyncio.to_thread(apply_gain_regions, background_source, ducked, duck_regions, DUCK_GAIN):
                background_input = ducked
            else:
                print("[export] Приглушение фона не удалось — фон без приглушения", flush=True)
                background_input = background_source
            inputs += ["-i", str(background_input)]
            filters.append(f"[{next_input}:a]{stereo},volume={volume:.3f},apad,atrim=duration={duration_str}[bg]")
            mix_labels.append("[bg]")
            next_input += 1
        else:
            filters.append(f"anullsrc=r=44100:cl=stereo,atrim=duration={duration_str}[bg]")
            mix_labels.append("[bg]")

        if stems is not None and keep_reactions:
            reactions = work / "reactions.flac"
            if await asyncio.to_thread(apply_gain_regions, stems["vocals_raw"], reactions, mute_regions, 0.0):
                inputs += ["-i", str(reactions)]
                filters.append(f"[{next_input}:a]{stereo},volume={volume:.3f},apad,atrim=duration={duration_str}[rx]")
                mix_labels.append("[rx]")
                next_input += 1
            else:
                print("[export] Не удалось подготовить реакции оригинала — экспорт без них", flush=True)

        dub_track = work / "dub.flac"
        rendered, skipped = await asyncio.to_thread(render_dub_track, specs, valid_segments, output_duration, dub_track)
        if not rendered:
            return {"ok": False, "error": "Не удалось собрать дорожку дубляжа (ffmpeg) — подробности в терминале"}
        inputs += ["-i", str(dub_track)]
        filters.append(f"[{next_input}:a]{stereo},apad,atrim=duration={duration_str}[dub]")
        mix_labels.append("[dub]")
        next_input += 1

        filters.append(
            f"{''.join(mix_labels)}amix=inputs={len(mix_labels)}:duration=longest:normalize=0:dropout_transition=0,"
            f"atrim=duration={duration_str}[final]"
        )

        if video_has_picture:
            tail_extension = max(0.0, output_duration - video_duration)
            video_options = ["-map", "0:v:0", "-c:v", "copy"]
            if tail_extension > 0.01:
                video_options = [
                    "-map", "0:v:0",
                    "-vf", f"tpad=stop_mode=clone:stop_duration={tail_extension:.3f}",
                    "-c:v", "libx264", "-preset", "veryfast", "-crf", "18",
                ]
            output = EXPORTS / f"dub_{uuid.uuid4().hex[:8]}.mp4"
        else:
            video_options = []  # загружен звук без видео — отдаём звук
            output = EXPORTS / f"dub_{uuid.uuid4().hex[:8]}.m4a"

        command = [
            "ffmpeg", "-y", *inputs, "-filter_complex", ";".join(filters),
            *video_options, "-map", "[final]", "-c:a", "aac",
            "-b:a", "192k", "-movflags", "+faststart", "-t", duration_str, str(output),
        ]
        try:
            result = await asyncio.to_thread(subprocess.run, command, capture_output=True, text=True, timeout=1800)
        except FileNotFoundError:
            return {"ok": False, "error": "ffmpeg/ffprobe не установлен"}
        except subprocess.TimeoutExpired:
            return {"ok": False, "error": "Экспорт занял больше 30 минут"}
        except OSError as exc:
            return {"ok": False, "error": f"Не удалось запустить ffmpeg: {exc}"}
        if result.returncode != 0:
            return {"ok": False, "error": result.stderr[-800:]}

    mode = "фон после очистки" + (" + реакции" if stems is not None and keep_reactions else "") if stems else "звук оригинала целиком"
    print(f"[export] {len(specs)} реплик, {mode}, наложений: {len(warnings)}"
          f"{f', пропущено: {len(skipped)}' if skipped else ''} -> {output.name}", flush=True)
    return {
        "ok": True,
        "url": f"/exports/{output.name}",
        "filename": output.name,
        "usedStems": stems is not None,
        "warnings": warnings,
        "skipped": skipped,
    }


app.mount("/uploads", StaticFiles(directory=str(UPLOADS)), name="uploads")
app.mount("/exports", StaticFiles(directory=str(EXPORTS)), name="exports")

if __name__ == "__main__":
    import uvicorn

    host = os.getenv("JARCUT_HOST", "127.0.0.1").strip() or "127.0.0.1"
    port = int(os.getenv("JARCUT_PORT", "8000"))
    endpoint = gpu_endpoint()
    voice_settings = omnivoice_settings()
    print(f"\nJarCut 2.0 -> http://localhost:{port}"
          + ("" if host in ("127.0.0.1", "localhost") else f"  (открыт для сети: {host} — без пароля!)"))
    gemini = gemini_config()
    print(f"Перевод: {gemini['model']} (через {'AI Studio' if gemini['backend'] == 'aistudio' else 'Vertex AI'})")
    print(f"Тайминги: ElevenLabs Scribe ({SCRIBE_MODEL})")
    print(f"Очистка + озвучка (Colab): {endpoint[0] if endpoint else 'JARCUT_GPU_URL НЕ ЗАДАН в .env'}")
    print(f"OmniVoice: шагов {voice_settings['num_step']}, guidance {voice_settings['guidance_scale']}, "
          f"референс {voice_settings['ref_source']}/{voice_settings['ref_mode']} ~{voice_settings['ref_target']:.0f} с, "
          f"подгонка длины {'вкл' if voice_settings['fit_duration'] else 'выкл'} — меняется в .env на лету")
    print(f"Ключ Gemini: {'из ' + gemini['source'] + ' (' + mask_key(gemini['key']) + ')' if gemini['key'] else 'НЕ ЗАДАН'}"
          " — .env для Gemini перечитывается на лету")
    print(f"Ключ ElevenLabs: {'OK' if ELEVENLABS_API_KEY else 'НЕ ЗАДАН'}\n")
    uvicorn.run(app, host=host, port=port)
