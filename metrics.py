#!/usr/bin/env python3
"""
Считает PSNR и SSIM между апскейленными картинками (results/)
и эталонными (benchmark/).

Соответствие по имени файла:
  results/baboon_out.png  <->  benchmark/baboon.png
  results/photo_out.png   <->  benchmark/photo.png

Использование:
  python metrics.py --results results/ --benchmark benchmark/
"""

import argparse
import sys
from pathlib import Path

try:
    import cv2
    import numpy as np
    from skimage.metrics import peak_signal_noise_ratio as psnr
    from skimage.metrics import structural_similarity as ssim
except ImportError:
    print("Устанавливаю зависимости...")
    import subprocess
    subprocess.check_call([sys.executable, "-m", "pip", "install",
                           "opencv-python-headless", "scikit-image", "numpy", "-q"])
    import cv2
    import numpy as np
    from skimage.metrics import peak_signal_noise_ratio as psnr
    from skimage.metrics import structural_similarity as ssim


IMG_EXTS = {".png", ".jpg", ".jpeg", ".bmp", ".tiff", ".webp"}


def find_benchmark_match(result_path: Path, benchmark_dir: Path) -> Path | None:
    """
    Ищет эталон для result-файла.
    Real-ESRGAN добавляет суффикс _out к имени, убираем его.
    Примеры:
      baboon_out.png  -> baboon.png
      photo_out.png   -> photo.png
      img.png         -> img.png  (если суффикса нет)
    """
    stem = result_path.stem
    # убираем суффикс _out если есть
    if stem.endswith("_out"):
        base_stem = stem[:-4]
    else:
        base_stem = stem

    # ищем файл с тем же именем в любом поддерживаемом расширении
    for ext in IMG_EXTS:
        candidate = benchmark_dir / f"{base_stem}{ext}"
        if candidate.exists():
            return candidate
    return None


def load_image(path: Path) -> np.ndarray:
    img = cv2.imread(str(path))
    if img is None:
        raise ValueError(f"Не удалось загрузить: {path}")
    return cv2.cvtColor(img, cv2.COLOR_BGR2RGB)


def compute_metrics(result_img: np.ndarray,
                    benchmark_img: np.ndarray) -> tuple[float, float]:
    """
    Если размеры не совпадают — ресайзим эталон под результат
    (апскейл 4x увеличивает картинку, эталон может быть другого размера).
    """
    h, w = result_img.shape[:2]
    bh, bw = benchmark_img.shape[:2]

    if (h, w) != (bh, bw):
        benchmark_img = cv2.resize(
            benchmark_img, (w, h), interpolation=cv2.INTER_LANCZOS4
        )

    psnr_val = psnr(benchmark_img, result_img, data_range=255)
    ssim_val = ssim(benchmark_img, result_img,
                    data_range=255, channel_axis=2)
    return psnr_val, ssim_val


def main():
    parser = argparse.ArgumentParser(
        description="PSNR / SSIM: results vs benchmark"
    )
    parser.add_argument("--results",   default="results",   help="Папка с апскейленными картинками")
    parser.add_argument("--benchmark", default="benchmark", help="Папка с эталонными картинками")
    args = parser.parse_args()

    results_dir   = Path(args.results)
    benchmark_dir = Path(args.benchmark)

    if not results_dir.exists():
        print(f"❌ Папка results не найдена: {results_dir.resolve()}")
        sys.exit(1)
    if not benchmark_dir.exists():
        print(f"❌ Папка benchmark не найдена: {benchmark_dir.resolve()}")
        sys.exit(1)

    result_files = sorted(
        p for p in results_dir.iterdir() if p.suffix.lower() in IMG_EXTS
    )

    if not result_files:
        print(f"❌ В папке {results_dir} нет картинок")
        sys.exit(1)

    print()
    print("=" * 62)
    print(f"  {'Файл':<28}  {'PSNR (dB)':>10}  {'SSIM':>8}")
    print("=" * 62)

    psnr_vals, ssim_vals = [], []
    skipped = []

    for result_path in result_files:
        bench_path = find_benchmark_match(result_path, benchmark_dir)
        if bench_path is None:
            skipped.append(result_path.name)
            continue

        try:
            result_img    = load_image(result_path)
            benchmark_img = load_image(bench_path)
            psnr_val, ssim_val = compute_metrics(result_img, benchmark_img)

            psnr_vals.append(psnr_val)
            ssim_vals.append(ssim_val)

            name = result_path.name
            if len(name) > 28:
                name = "..." + name[-25:]
            print(f"  {name:<28}  {psnr_val:>10.2f}  {ssim_val:>8.4f}")

        except Exception as e:
            print(f"  ⚠️  {result_path.name}: ошибка — {e}")

    print("=" * 62)

    if psnr_vals:
        avg_psnr = np.mean(psnr_vals)
        avg_ssim = np.mean(ssim_vals)
        print(f"  {'Среднее':<28}  {avg_psnr:>10.2f}  {avg_ssim:>8.4f}")
        print("=" * 62)

        # Интерпретация качества
        print()
        if avg_psnr >= 40:
            quality = "🟢 Отличное (практически без потерь)"
        elif avg_psnr >= 30:
            quality = "🟡 Хорошее"
        elif avg_psnr >= 20:
            quality = "🟠 Среднее"
        else:
            quality = "🔴 Низкое"
        print(f"  Качество апскейла: {quality}")

    if skipped:
        print()
        print("  ⚠️  Эталон не найден для:")
        for name in skipped:
            print(f"     - {name}")
        print("  Убедись что в benchmark/ есть файлы с такими же именами")
        print("  (без суффикса _out)")

    print()


if __name__ == "__main__":
    main()
