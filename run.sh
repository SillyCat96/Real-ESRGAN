#!/usr/bin/env bash
# ============================================================
# Real-ESRGAN pipeline
#   1. benchmark/ -> make_lr.py -> pictures/  
#   2. pictures/  -> Real-ESRGAN -> results/  
#   3. results/ vs benchmark/ -> metrics.py    
#
# Использование:
#   ./run.sh                  # полный pipeline
#   ./run.sh --no-metrics     # без метрик
#   ./run.sh --scale 2        # LR в 2 раза (default: 4)
#   ./run.sh --regen          # пересоздать LR заново
#   ./run.sh photo.jpg        # один файл + метрики
# ============================================================

set -e

IMAGE_NAME="real-esrgan-cpu"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RESULTS_DIR="$SCRIPT_DIR/results"
BENCHMARK_DIR="$SCRIPT_DIR/benchmark"
PICTURES_DIR="$SCRIPT_DIR/pictures"

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
      if [ "$PREV_ARG" = "--scale" ]; then
        SCALE="$arg"
      else
        INPUT_ARG="$arg"
      fi
      ;;
  esac
  PREV_ARG="$arg"
done

# --- Сборка образа -------------------------------------------
if ! docker image inspect "$IMAGE_NAME" > /dev/null 2>&1; then
  echo "🔨 Собираем Docker-образ (первый раз ~5-10 минут)..."
  docker build -t "$IMAGE_NAME" "$SCRIPT_DIR"
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
    echo "❌ Папка benchmark/ не найдена."
    echo "   Положи HR-картинки (например Set14) в папку benchmark/"
    exit 1
  fi

  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  ШАГ 1/3 — Генерация LR из benchmark/ → pictures/"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""

  mkdir -p "$PICTURES_DIR"

  if [ "$REGEN" = true ]; then
    rm -rf "$PICTURES_DIR"/*
    echo "  ♻️  --regen: папка pictures/ очищена"
  fi

  docker run --rm \
    -v "$(pwd)/benchmark:/benchmark:ro" \
    -v "$(pwd)/pictures:/pictures" \
    -v "$(pwd)/make_lr.py:/make_lr.py:ro" \
    --entrypoint python3 \
    "$IMAGE_NAME" \
    /make_lr.py \
    --benchmark /benchmark \
    --pictures /pictures \
    --scale "$SCALE"

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
  echo "❌ Файл или папка не найдена: $INPUT_ABS"
  exit 1
fi

mkdir -p "$RESULTS_DIR"

if [ -f "$INPUT_ABS" ]; then
  INPUT_DIR="$(dirname "$INPUT_ABS")"
  INPUT_FILE="$(basename "$INPUT_ABS")"
  echo "📁 Апскейлим: $INPUT_FILE"
  echo "📁 Результат: $RESULTS_DIR/"
  echo ""

  docker run --rm \
    -v "${INPUT_DIR}:/input:ro" \
    -v "$(pwd)/results:/output" \
    "$IMAGE_NAME" \
    -i "/input/$INPUT_FILE" \
    2>&1 | grep -v "UserWarning\|functional_tensor\|warn\|removed in 0.17\|transforms.functional or"
else
  echo "📂 Апскейлим папку: $INPUT_ABS"
  echo "📁 Результат: $RESULTS_DIR/"
  echo ""

  docker run --rm \
    -v "${INPUT_ABS}:/input:ro" \
    -v "$(pwd)/results:/output" \
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
    echo "ℹ️  Папка benchmark/ не найдена — метрики пропущены."
  else
    echo ""
    if [ "$DEFAULT_MODE" = true ]; then
      echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
      echo "  ШАГ 3/3 — Метрики качества (PSNR / SSIM)"
      echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    else
      echo "Считаем метрики качества (PSNR / SSIM)..."
    fi
    echo ""

    REFERENCE_DIR="$SCRIPT_DIR/reference"
    REFERENCE_MOUNT=""
    REFERENCE_ARG=""
    if [ -d "$REFERENCE_DIR" ]; then
      REFERENCE_MOUNT="-v $(pwd)/reference:/reference:ro"
      REFERENCE_ARG="--reference /reference"
    fi

    docker run --rm \
      -v "$(pwd)/results:/results:ro" \
      -v "$(pwd)/benchmark:/benchmark:ro" \
      -v "$(pwd)/metrics.py:/metrics.py:ro" \
      $REFERENCE_MOUNT \
      --entrypoint python3 \
      "$IMAGE_NAME" \
      /metrics.py \
      --results /results \
      --benchmark /benchmark \
      $REFERENCE_ARG
  fi
fi
