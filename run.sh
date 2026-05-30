#!/usr/bin/env bash
# ============================================================
# Real-ESRGAN pipeline (v10)
#
# Использование:
#   ./run.sh                  # полный pipeline
#   ./run.sh --no-metrics     # без метрик
#   ./run.sh --scale 2        # LR в 2 раза (default: 4)
#   ./run.sh --regen          # пересоздать LR заново
#   ./run.sh photo.jpg        # один файл + метрики
# ============================================================

IMAGE_NAME="real-esrgan-cpu"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BENCHMARK_DIR="$SCRIPT_DIR/benchmark"
PICTURES_DIR="$SCRIPT_DIR/pictures"
RESULTS_DIR="$SCRIPT_DIR/results"

# --- Парсинг аргументов --------------------------------------
INPUT_ARG=""
RUN_METRICS=true
SCALE=4
REGEN=false
PREV_ARG=""

for arg in "$@"; do
  case "$arg" in
    --no-metrics) RUN_METRICS=false ;;
    --regen)      REGEN=true ;;
    --scale=*)    SCALE="${arg#*=}" ;;
    *)
      if [ "$PREV_ARG" = "--scale" ]; then SCALE="$arg"
      else INPUT_ARG="$arg"
      fi ;;
  esac
  PREV_ARG="$arg"
done

# --- Безопасное создание папки -------------------------------
# Если git случайно создал файл вместо папки — исправляем
safe_mkdir() {
  local dir="$1"
  if [ -f "$dir" ]; then
    echo "  ⚠️  '$dir' — файл вместо папки, исправляю..."
    rm -f "$dir"
  fi
  mkdir -p "$dir"
}

# --- Конвертация пути для docker -v --------------------------
# Git Bash на Windows даёт пути вида /mnt/e/... или /e/...
# Docker Desktop на Windows требует e:/...
# Linux/Mac оставляем как есть
to_docker_path() {
  local p="$1"
  # /mnt/e/foo  →  e:/foo   (Git Bash + WSL стиль)
  if echo "$p" | grep -qE '^/mnt/[a-zA-Z]/'; then
    echo "$p" | sed 's|^/mnt/\([a-zA-Z]\)/|\1:/|'
  # /e/foo  →  e:/foo   (MSYS2 / Git Bash стиль)
  elif echo "$p" | grep -qE '^/[a-zA-Z]/'; then
    echo "$p" | sed 's|^/\([a-zA-Z]\)/|\1:/|'
  # C:\foo или C:/foo  →  оставляем, заменяем \ на /
  elif echo "$p" | grep -qE '^[a-zA-Z]:[/\\]'; then
    echo "$p" | sed 's|\\|/|g'
  else
    # Linux / Mac — путь уже правильный
    echo "$p"
  fi
}

# --- Сборка образа -------------------------------------------
if ! docker image inspect "$IMAGE_NAME" > /dev/null 2>&1; then
  echo "🔨 Собираем Docker-образ (первый раз ~5-10 минут)..."
  docker build -t "$IMAGE_NAME" "$SCRIPT_DIR" || { echo "❌ Ошибка сборки"; exit 1; }
else
  echo "✅ Образ '$IMAGE_NAME' уже есть."
fi

# ============================================================
# ШАГ 1 — Генерация LR
# ============================================================
DEFAULT_MODE=false

if [ -z "$INPUT_ARG" ]; then
  DEFAULT_MODE=true

  if [ ! -d "$BENCHMARK_DIR" ]; then
    echo ""
    echo "❌ Папка benchmark/ не найдена: $BENCHMARK_DIR"
    echo "   Положи HR-картинки в папку benchmark/ и запусти снова."
    exit 1
  fi

  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  ШАГ 1/3 — Генерация LR из benchmark/ → pictures/"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""

  safe_mkdir "$PICTURES_DIR"

  if [ "$REGEN" = true ]; then
    rm -rf "${PICTURES_DIR:?}"/*
    echo "  ♻️  --regen: pictures/ очищена"
  fi

  DOCKER_BENCHMARK="$(to_docker_path "$BENCHMARK_DIR")"
  DOCKER_PICTURES="$(to_docker_path "$PICTURES_DIR")"

  echo "  [debug] benchmark → $DOCKER_BENCHMARK"
  echo "  [debug] pictures  → $DOCKER_PICTURES"
  echo ""

  docker run --rm -i \
    -v "${DOCKER_BENCHMARK}:/benchmark:ro" \
    -v "${DOCKER_PICTURES}:/pictures" \
    --entrypoint python3 \
    "$IMAGE_NAME" - \
    --benchmark /benchmark \
    --pictures  /pictures \
    --scale     "$SCALE" \
    < "$SCRIPT_DIR/make_lr.py" \
    || { echo "❌ Ошибка при генерации LR"; exit 1; }

  INPUT_ARG="$PICTURES_DIR"
fi

# ============================================================
# ШАГ 2 — Апскейл
# ============================================================
echo ""
if [ "$DEFAULT_MODE" = true ]; then
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  ШАГ 2/3 — Апскейл (Real-ESRGAN x4)"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
fi
echo ""

if [ -f "$INPUT_ARG" ] || [ -d "$INPUT_ARG" ]; then
  INPUT_ABS="$(cd "$(dirname "$INPUT_ARG")" && pwd)/$(basename "$INPUT_ARG")"
else
  INPUT_ABS="$INPUT_ARG"
fi

if [ ! -e "$INPUT_ABS" ]; then
  echo "❌ Не найдено: $INPUT_ABS"
  exit 1
fi

safe_mkdir "$RESULTS_DIR"

DOCKER_RESULTS="$(to_docker_path "$RESULTS_DIR")"

if [ -f "$INPUT_ABS" ]; then
  INPUT_DIR="$(dirname "$INPUT_ABS")"
  INPUT_FILE="$(basename "$INPUT_ABS")"
  DOCKER_INPUT="$(to_docker_path "$INPUT_DIR")"
  echo "🖼  Апскейлим: $INPUT_FILE"
  echo "📁 Результат: $RESULTS_DIR/"
  echo ""
  docker run --rm \
    -v "${DOCKER_INPUT}:/input:ro" \
    -v "${DOCKER_RESULTS}:/output" \
    "$IMAGE_NAME" \
    -i "/input/$INPUT_FILE" \
    2>&1 | grep -v "UserWarning\|functional_tensor\|warn\|removed in 0.17\|transforms.functional or"
else
  DOCKER_INPUT="$(to_docker_path "$INPUT_ABS")"
  echo "📂 Апскейлим папку: $INPUT_ABS"
  echo "📁 Результат: $RESULTS_DIR/"
  echo ""
  docker run --rm \
    -v "${DOCKER_INPUT}:/input:ro" \
    -v "${DOCKER_RESULTS}:/output" \
    "$IMAGE_NAME" \
    2>&1 | grep -v "UserWarning\|functional_tensor\|warn\|removed in 0.17\|transforms.functional or"
fi

echo ""
echo "✅ Апскейл завершён!"

# ============================================================
# ШАГ 3 — Метрики
# ============================================================
if [ "$RUN_METRICS" = true ]; then
  if [ ! -d "$BENCHMARK_DIR" ]; then
    echo ""
    echo "ℹ️  benchmark/ не найдена — метрики пропущены."
  else
    echo ""
    if [ "$DEFAULT_MODE" = true ]; then
      echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
      echo "  ШАГ 3/3 — Метрики качества (PSNR / SSIM)"
      echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    else
      echo "📊 Считаем метрики (PSNR / SSIM)..."
    fi
    echo ""

    DOCKER_RESULTS_M="$(to_docker_path "$RESULTS_DIR")"
    DOCKER_BENCHMARK_M="$(to_docker_path "$BENCHMARK_DIR")"

    docker run --rm -i \
      -v "${DOCKER_RESULTS_M}:/results:ro" \
      -v "${DOCKER_BENCHMARK_M}:/benchmark:ro" \
      --entrypoint python3 \
      "$IMAGE_NAME" - \
      --results   /results \
      --benchmark /benchmark \
      < "$SCRIPT_DIR/metrics.py"
  fi
fi
