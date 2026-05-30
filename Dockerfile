# ============================================================
# Real-ESRGAN Docker — CPU-only
# ============================================================
FROM python:3.10-slim

# --- 1. Системные зависимости --------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    wget \
    libgl1 \
    libglib2.0-0 \
    libsm6 \
    libxext6 \
    libxrender-dev \
 && rm -rf /var/lib/apt/lists/*

# --- 2. Рабочая директория -----------------------------------
WORKDIR /app

# --- 3. Клонируем репозиторий --------------------------------
RUN git clone https://github.com/SillyCat96/Real-ESRGAN.git .

# --- 4. Копируем наш requirements.txt -----------------------
COPY requirements.txt /app/requirements.txt

# --- 5. PyTorch CPU (без CUDA — стабильно и легко) ----------
RUN pip install --no-cache-dir \
    torch==2.0.1+cpu \
    torchvision==0.15.2+cpu \
    --index-url https://download.pytorch.org/whl/cpu

# --- 6. Зависимости проекта ----------------------------------
RUN pip install --no-cache-dir -r requirements.txt

# --- 7. Устанавливаем realesrgan как пакет -------------------
#   basicsr уже стоит из requirements, поэтому только realesrgan
RUN pip install --no-cache-dir -e .

# --- 8. Скачиваем модель в /app/weights (абсолютный путь) ----
RUN mkdir -p /app/weights && \
    wget -q --show-progress \
    https://github.com/xinntao/Real-ESRGAN/releases/download/v0.1.0/RealESRGAN_x4plus.pth \
    -O /app/weights/RealESRGAN_x4plus.pth

# --- 9. Папки для ввода/вывода -------------------------------
RUN mkdir -p /input /output

# --- 10. ENTRYPOINT: запускаем из /app, путь к модели явный --
WORKDIR /app
ENTRYPOINT ["python", "inference_realesrgan.py", \
    "-n", "RealESRGAN_x4plus", \
    "--model_path", "/app/weights/RealESRGAN_x4plus.pth", \
    "-i", "/input", \
    "-o", "/output", \
    "--fp32"]