#!/usr/bin/env python3
"""
Генерирует LR (низкое разрешение) из HR (высокое разрешение) картинок.

Берёт картинки из benchmark/, уменьшает в scale раз методом BICUBIC,
сохраняет в pictures/ с теми же именами.

Использование:
  python make_lr.py --benchmark benchmark/ --pictures pictures/ --scale 4
"""
#!/usr/bin/env python3
import argparse
import sys
from pathlib import Path

try:
    from PIL import Image
except ImportError:
    import subprocess
    subprocess.check_call([sys.executable, "-m", "pip", "install", "Pillow", "-q"])
    from PIL import Image

IMG_EXTS = {".png", ".jpg", ".jpeg", ".bmp", ".tiff", ".webp"}

def main():
    parser = argparse.ArgumentParser(description="HR -> LR downscaler")
    parser.add_argument("--benchmark", default="benchmark")
    parser.add_argument("--pictures", default="pictures")
    parser.add_argument("--scale", type=int, default=4)
    args = parser.parse_args()

    benchmark_dir = Path(args.benchmark)
    pictures_dir = Path(args.pictures)
    scale = args.scale

    if not benchmark_dir.exists():
        print(f"Папка benchmark не найдена: {benchmark_dir.resolve()}")
        sys.exit(1)

    # Диагностика: выведем список файлов, которые видит Python
    all_files = list(benchmark_dir.iterdir())
    print(f"DEBUG: Все файлы в {benchmark_dir}: {[f.name for f in all_files]}")
    
    hr_files = [p for p in all_files if p.suffix.lower() in IMG_EXTS]
    print(f"DEBUG: Найдено HR-файлов: {len(hr_files)}")
    for f in hr_files:
        print(f"DEBUG:   {f.name}")

    if not hr_files:
        print(f"  В папке {benchmark_dir} нет картинок")
        sys.exit(1)

    pictures_dir.mkdir(parents=True, exist_ok=True)
    print(f"Масштаб: x{scale} (BICUBIC)")
    print(f"Источник: {benchmark_dir.resolve()}")
    print(f"Результат: {pictures_dir.resolve()}")

    generated = 0
    skipped = 0
    for hr_path in hr_files:
        out_path = pictures_dir / hr_path.name
        if out_path.exists():
            print(f"⏭ {hr_path.name} уже есть, пропускаем")
            skipped += 1
            continue
        try:
            img = Image.open(hr_path).convert("RGB")
            w, h = img.size
            new_w, new_h = max(1, w // scale), max(1, h // scale)
            lr = img.resize((new_w, new_h), Image.BICUBIC)
            lr.save(out_path)
            print(f"✅ {hr_path.name} {w}x{h} -> {new_w}x{new_h}")
            generated += 1
        except Exception as e:
            print(f"⚠️ {hr_path.name}: ошибка {e}")
    print(f"Сгенерировано: {generated} | Пропущено: {skipped}")

if __name__ == "__main__":
    main()