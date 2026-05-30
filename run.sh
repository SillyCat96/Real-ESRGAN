#!/usr/bin/env bash
# ============================================================
# Real-ESRGAN pipeline (v8):
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

# Не используем set -e — обрабатываем ошибки явно
IMAGE_NAME="real-esrgan-cpu"
# SCRIPT_DIR всегда указывает на папку со скриптом,
# независимо от того откуда запущен bash
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
      if [ "$PREV_ARG" = "--scale" ]; then
        SCALE="$arg"
      else
        INPUT_ARG="$arg"
      fi
      ;;
  esac
  PREV_ARG="$arg"
done

# --- Хелпер: безопасно создать папку ------------------------
# Если вдруг на месте папки лежит файл (артефакт git) — удаляем его
safe_mkdir() {
  local dir="$1"
  if [ -f "$dir" ]; then
    echo "  ⚠️  '$dir' — это файл, удаляю и создаю папку..."
    rm -f "$dir"
  fi
  mkdir -p "$dir"
}

# --- Хелпер: конвертация пути для docker -v на Windows ------
to_docker_path() {
  local p="$1"
  # Windows-путь C:\... или C:/...
  if echo "$p" | grep -qE '^[A-Za-z]:[/\\]'; then
    echo "$p" | sed 's|\\|/|g' | sed 's|^\([A-Za-z]\):|/\L\1|'
  # WSL-путь /mnt/c/...
  elif echo "$p" | grep -qE '^/mnt/[a-z]/'; then
    echo "$p" | sed 's|^/mnt/\([a-z]\)/|/\1/|'
  else
    echo "$p"
  fi
}

# --- Сборка образа -------------------------------------------
if ! docker image inspect "$IMAGE_NAME" > /dev/null 2>&1; then
  echo "🔨 Собираем Docker-образ (первый раз ~5-10 минут)..."
  docker build -t "$IMAGE_NAME" "$SCRIPT_DIR" || {
    echo "❌ Ошибка сборки образа"
    exit 1
  }
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
    echo "   Положи HR-картинки (Set14 и т.п.) в папку benchmark/"
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
    echo "  ♻️  --regen: папка pictures/ очищена"
  fi

  docker run --rm \
    -v "$(to_docker_path "$BENCHMARK_DIR"):/benchmark:ro" \
    -v "$(to_docker_path "$PICTURES_DIR"):/pictures" \
    -v "$(to_docker_path "$SCRIPT_DIR/make_lr.py"):/make_lr.py:ro" \
    --entrypoint python3 \
    "$IMAGE_NAME" \
    /make_lr.py \
    --benchmark /benchmark \
    --pictures  /pictures \
    --scale     "$SCALE" || {
      echo "❌ Ошибка при генерации LR"
      exit 1
    }

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

# Резолвим INPUT_ABS — всегда абсолютный путь
if [ -f "$INPUT_ARG" ] || [ -d "$INPUT_ARG" ]; then
  INPUT_ABS="$(cd "$(dirname "$INPUT_ARG")" && pwd)/$(basename "$INPUT_ARG")"
else
  # Путь мог быть абсолютным сразу
  INPUT_ABS="$INPUT_ARG"
fi

if [ ! -e "$INPUT_ABS" ]; then
  echo "❌ Файл или папка не найдена: $INPUT_ABS"
  exit 1
fi

safe_mkdir "$RESULTS_DIR"

if [ -f "$INPUT_ABS" ]; then
  INPUT_DIR="$(dirname "$INPUT_ABS")"
  INPUT_FILE="$(basename "$INPUT_ABS")"
  echo "🖼  Апскейлим: $INPUT_FILE"
  echo "📁 Результат: $RESULTS_DIR/"
  echo ""

  docker run --rm \
    -v "$(to_docker_path "$INPUT_DIR"):/input:ro" \
    -v "$(to_docker_path "$RESULTS_DIR"):/output" \
    "$IMAGE_NAME" \
    -i "/input/$INPUT_FILE" \
    2>&1 | grep -v "UserWarning\|functional_tensor\|warn\|removed in 0.17\|transforms.functional or"
else
  echo "📂 Апскейлим папку: $INPUT_ABS"
  echo "📁 Результат: $RESULTS_DIR/"
  echo ""

  docker run --rm \
    -v "$(to_docker_path "$INPUT_ABS"):/input:ro" \
    -v "$(to_docker_path "$RESULTS_DIR"):/output" \
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
      echo "📊 Считаем метрики качества (PSNR / SSIM)..."
    fi
    echo ""

    docker run --rm \
      -v "$(to_docker_path "$RESULTS_DIR"):/results:ro" \
      -v "$(to_docker_path "$BENCHMARK_DIR"):/benchmark:ro" \
      -v "$(to_docker_path "$SCRIPT_DIR/metrics.py"):/metrics.py:ro" \
      --entrypoint python3 \
      "$IMAGE_NAME" \
      /metrics.py \
      --results   /results \
      --benchmark /benchmark
  fi
fi
