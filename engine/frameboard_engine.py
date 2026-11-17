#!/usr/bin/env python3
"""FrameBoard Engine: разбор видео на стоп-кадры, раскадровка сцен и цветовые палитры.

Поддерживает два основных сценария:
1. --mode faces: отбор лучших кадров каждого ведущего/героя (первая минута или всё видео).
2. --mode storyboard: раскадровка клипов/референсов (по смене сцен или посекундно),
   расчёт длительности планов, извлечение палитры из 5 HEX-цветов и сборка contact_sheet.jpg.
"""

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path

import cv2
import numpy as np

HERE = Path(__file__).resolve().parent
PROTOCOL = sys.stdout
sys.stdout = sys.stderr

STAGE_SCAN = 0.78
STAGE_SCORE = 0.18
STAGE_EXPORT = 0.04

WEIGHTS = {
    "sharpness": 0.25,
    "eyes": 0.20,
    "size": 0.15,
    "pose": 0.15,
    "mouth": 0.15,
    "exposure": 0.10,
}


def emit(kind, **payload):
    PROTOCOL.write(json.dumps({"type": kind, **payload}, ensure_ascii=False) + "\n")
    PROTOCOL.flush()


def progress(fraction, message):
    emit("progress", fraction=round(min(max(fraction, 0.0), 1.0), 4), message=message)


def log(*parts):
    print(*parts, file=sys.stderr, flush=True)


def clip01(value):
    return float(min(max(value, 0.0), 1.0))


def format_mmss(seconds: float) -> str:
    total = max(0, int(round(seconds)))
    h, rem = divmod(total, 3600)
    m, s = divmod(rem, 60)
    return f"{h:02d}:{m:02d}:{s:02d}" if h > 0 else f"{m:02d}:{s:02d}"


def timecode(seconds: float) -> str:
    total = max(0.0, float(seconds))
    h = int(total // 3600)
    m = int((total % 3600) // 60)
    s = total % 60
    return f"{h:02d}:{m:02d}:{s:06.3f}"


def find_tool(name, explicit=None):
    if explicit and Path(explicit).is_file():
        return explicit
    found = shutil.which(name)
    if found:
        return found
    for candidate in (
        f"/opt/homebrew/bin/{name}",
        f"/usr/local/bin/{name}",
        f"/Applications/Workspace.app/Contents/Resources/bin/{name}",
    ):
        if Path(candidate).is_file():
            return candidate
    raise RuntimeError(f"Не найден {name}. Установите ffmpeg (brew install ffmpeg).")


def find_models_dir(explicit=None) -> Path:
    candidates = []
    if explicit:
        candidates.append(Path(explicit).expanduser())
    candidates += [
        HERE / "models",
        Path.home() / "Documents/M24Workspace/StopFrames/models",
        Path.home() / "Documents/Проекты Антона/Приложения и инструменты/M24Workspace/StopFrames/models",
    ]
    for p in candidates:
        if (p / "models" / "buffalo_s").is_dir() or (p / "buffalo_s").is_dir():
            return p
    return candidates[0]


@dataclass
class VideoInfo:
    width: int
    height: int
    duration: float


def probe(ffprobe, video):
    cmd = [
        ffprobe, "-v", "error", "-select_streams", "v:0",
        "-show_entries", "stream=width,height:format=duration",
        "-of", "json", str(video),
    ]
    res = subprocess.run(cmd, capture_output=True, text=True)
    if res.returncode != 0:
        raise RuntimeError(res.stderr.strip() or "ffprobe failed")
    data = json.loads(res.stdout or "{}")
    stream = (data.get("streams") or [{}])[0]
    fmt = data.get("format") or {}
    return VideoInfo(
        width=int(stream.get("width") or 1920),
        height=int(stream.get("height") or 1080),
        duration=float(fmt.get("duration") or 0.0),
    )


def extract_palette(image_bgr, k: int = 5) -> list[str]:
    """Извлекает 5 доминирующих цветов кадра в формате #RRGGBB."""
    if image_bgr is None or image_bgr.size == 0:
        return []
    small = cv2.resize(image_bgr, (64, 36), interpolation=cv2.INTER_AREA)
    rgb = cv2.cvtColor(small, cv2.COLOR_BGR2RGB)
    pixels = rgb.reshape(-1, 3).astype(np.float32)
    criteria = (cv2.TERM_CRITERIA_EPS + cv2.TERM_CRITERIA_MAX_ITER, 10, 1.0)
    _, labels, centers = cv2.kmeans(pixels, k, None, criteria, 3, cv2.KMEANS_PP_CENTERS)
    counts = np.bincount(labels.flatten(), minlength=k)
    order = np.argsort(-counts)
    hex_colors = []
    for idx in order:
        r, g, b = [int(clip01(c / 255.0) * 255) for c in centers[idx]]
        hex_colors.append(f"#{r:02X}{g:02X}{b:02X}")
    return hex_colors


def _hex_to_bgr(hex_str: str) -> tuple[int, int, int]:
    h = hex_str.lstrip("#")
    if len(h) != 6:
        return (128, 128, 128)
    r, g, b = int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16)
    return (b, g, r)


def build_contact_sheet(frame_entries, output_path: Path, title_text: str):
    if not frame_entries:
        return None
    cols = 4
    rows = (len(frame_entries) + cols - 1) // cols
    cell_w, cell_h = 440, 268
    pad = 16
    header_h = 68

    canvas_w = cols * cell_w + (cols + 1) * pad
    canvas_h = header_h + rows * cell_h + (rows + 1) * pad
    canvas = np.full((canvas_h, canvas_w, 3), (15, 18, 28), dtype=np.uint8)

    cv2.putText(canvas, title_text[:85], (pad, 44), cv2.FONT_HERSHEY_SIMPLEX, 0.85, (240, 244, 252), 2, cv2.LINE_AA)

    for idx, entry in enumerate(frame_entries):
        r, c = divmod(idx, cols)
        x0 = pad + c * (cell_w + pad)
        y0 = header_h + pad + r * (cell_h + pad)
        img = cv2.imread(entry["path"])
        if img is None:
            continue
        ih, iw = img.shape[:2]
        img_box_h = cell_h - 22
        scale = min(cell_w / max(iw, 1), img_box_h / max(ih, 1))
        nw, nh = max(1, int(iw * scale)), max(1, int(ih * scale))
        resized = cv2.resize(img, (nw, nh), interpolation=cv2.INTER_AREA)
        dx = x0 + (cell_w - nw) // 2
        dy = y0 + (img_box_h - nh) // 2
        canvas[dy:dy + nh, dx:dx + nw] = resized

        # Timestamp + duration pill
        dur = entry.get("duration_sec", 0.0)
        label = f"#{entry['index']}  {entry['timestamp']}"
        if dur and dur > 0:
            label += f" ({dur:.1f}s)"
        (tw, th), _ = cv2.getTextSize(label, cv2.FONT_HERSHEY_SIMPLEX, 0.50, 1)
        cv2.rectangle(canvas, (x0 + 8, y0 + 8), (x0 + 22 + tw, y0 + 18 + th), (10, 13, 20), -1)
        cv2.putText(canvas, label, (x0 + 14, y0 + 13 + th), cv2.FONT_HERSHEY_SIMPLEX, 0.50, (251, 191, 36), 1, cv2.LINE_AA)

        # Palette strip at bottom of cell
        palette = entry.get("palette") or []
        if palette:
            sw = cell_w // len(palette)
            for p_i, hx in enumerate(palette):
                px0 = x0 + p_i * sw
                px1 = x0 + cell_w if p_i == len(palette) - 1 else px0 + sw
                cv2.rectangle(canvas, (px0, y0 + img_box_h + 4), (px1, y0 + cell_h - 2), _hex_to_bgr(hx), -1)

    cv2.imwrite(str(output_path), canvas, [cv2.IMWRITE_JPEG_QUALITY, 92])
    return output_path


def run_storyboard(args):
    started = time.monotonic()
    video = Path(args.video).expanduser().resolve()
    if not video.is_file():
        raise RuntimeError(f"Файл не найден: {video}")
    ffmpeg = find_tool("ffmpeg", args.ffmpeg)
    ffprobe = find_tool("ffprobe", args.ffprobe)

    progress(0.05, "Читаю параметры видео…")
    info = probe(ffprobe, video)

    output = Path(args.output_dir).expanduser() if args.output_dir else video.parent / f"{video.stem}_FrameBoard"
    output.mkdir(parents=True, exist_ok=True)
    for old in list(output.glob("frame_*.jpg")) + list(output.glob("raw_*.jpg")) + [output / "contact_sheet.jpg", output / "report.json"]:
        if old.exists():
            old.unlink()

    sb_mode = args.storyboard_mode
    max_frames = max(1, args.max_frames)
    tmp_pattern = str(output / "raw_%04d.jpg")

    cmd = [ffmpeg, "-hide_banner", "-loglevel", "info", "-nostdin", "-i", str(video)]
    if args.max_seconds > 0:
        cmd += ["-t", f"{args.max_seconds:.3f}"]

    if sb_mode == "scene":
        progress(0.15, "Ищу монтажные склейки и смены сцен…")
        vf = f"select='eq(n,0)+gt(scene,{args.scene_threshold:.2f})',showinfo"
        cmd += ["-vf", vf, "-fps_mode", "vfr", "-frames:v", str(max_frames), "-q:v", "2", tmp_pattern]
    else:
        interval = max(0.5, args.interval)
        progress(0.15, f"Раскадровка с шагом {interval:g} сек…")
        vf = f"fps=1/{interval:.4f},showinfo"
        cmd += ["-vf", vf, "-frames:v", str(max_frames), "-q:v", "2", tmp_pattern]

    proc = subprocess.run(cmd, capture_output=True, text=True)
    raw_files = sorted(output.glob("raw_*.jpg"))
    if proc.returncode != 0 and not raw_files:
        raise RuntimeError(proc.stderr.strip()[:400] or "ffmpeg завершился с ошибкой")

    pts_times = [float(m.group(1)) for m in re.finditer(r"pts_time:([0-9]+(?:\.[0-9]+)?)", proc.stderr or "")]
    if not raw_files:
        raise RuntimeError("Не удалось извлечь кадры (попробуйте интервальный режим или уменьшите порог сцены).")

    progress(0.65, f"Считаю палитру цветов и длительность для {len(raw_files)} кадров…")
    storyboard_frames = []
    for i, raw_path in enumerate(raw_files):
        sec = pts_times[i] if i < len(pts_times) else (i * args.interval)
        if i + 1 < len(raw_files):
            next_sec = pts_times[i + 1] if i + 1 < len(pts_times) else ((i + 1) * args.interval)
        else:
            next_sec = info.duration if info.duration > sec else sec
        shot_dur = max(0.0, next_sec - sec)

        ts = format_mmss(sec)
        safe_ts = ts.replace(":", "-")
        final_path = output / f"frame_{i + 1:03d}_{safe_ts}.jpg"
        raw_path.rename(final_path)

        img = cv2.imread(str(final_path))
        palette = extract_palette(img, k=5)

        storyboard_frames.append({
            "index": i + 1,
            "seconds": round(sec, 2),
            "duration_sec": round(shot_dur, 1),
            "timestamp": ts,
            "path": str(final_path),
            "palette": palette,
        })

    progress(0.88, "Собираю сводную таблицу (Contact Sheet)…")
    sheet_path = output / "contact_sheet.jpg"
    avg_shot = (info.duration / max(len(storyboard_frames), 1)) if info.duration > 0 else 0.0
    build_contact_sheet(
        storyboard_frames,
        sheet_path,
        f"{video.stem}  |  {len(storyboard_frames)} shots  |  avg {avg_shot:.1f}s/shot",
    )

    elapsed = time.monotonic() - started
    report = {
        "mode": "storyboard",
        "storyboard_mode": sb_mode,
        "video": str(video),
        "video_duration": round(info.duration, 1),
        "avg_shot_seconds": round(avg_shot, 1),
        "elapsed_seconds": round(elapsed, 1),
        "contact_sheet": str(sheet_path) if sheet_path.exists() else None,
        "frames": storyboard_frames,
    }
    (output / "report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    progress(1.0, "Готово")
    emit(
        "result",
        mode="storyboard",
        output_dir=str(output),
        report=str(output / "report.json"),
        video_duration=round(info.duration, 1),
        avg_shot_seconds=round(avg_shot, 1),
        elapsed_seconds=round(elapsed, 1),
        people=[],
        contact_sheet=str(sheet_path) if sheet_path.exists() else None,
        storyboard_frames=storyboard_frames,
    )


# ----------------- РЕЖИМ ЛИЦА И ВЕДУЩИЕ -----------------

@dataclass
class Detection:
    frame: int
    seconds: float
    bbox: np.ndarray
    kps: np.ndarray
    embedding: np.ndarray
    height_fraction: float
    sharpness: float
    rough_pose: float
    exposure: float


@dataclass
class Candidate:
    seconds: float
    scores: dict
    raw: dict
    total: float = 0.0


def scan_frames(ffmpeg, video, step, width, height, hwaccel, max_seconds=0.0):
    cmd = [ffmpeg, "-hide_banner", "-loglevel", "error", "-nostdin"]
    if hwaccel:
        cmd += ["-hwaccel", "videotoolbox"]
    cmd += ["-i", str(video)]
    if max_seconds > 0:
        cmd += ["-t", f"{max_seconds:.3f}"]
    cmd += ["-an", "-sn", "-dn", "-vf", f"fps={1 / step:.6f},scale={width}:{height}:flags=area", "-pix_fmt", "bgr24", "-f", "rawvideo", "-"]
    frame_bytes = width * height * 3
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=frame_bytes * 4)
    index = 0
    try:
        while True:
            buf = proc.stdout.read(frame_bytes)
            if len(buf) < frame_bytes:
                break
            yield index, np.frombuffer(buf, np.uint8).reshape(height, width, 3)
            index += 1
    finally:
        proc.stdout.close()
        stderr = proc.stderr.read().decode("utf-8", "replace")
        proc.wait()
    if proc.returncode != 0 and index == 0:
        raise RuntimeError(stderr.strip()[:300] or "ffmpeg завершился с ошибкой")


def grab_frame(ffmpeg, video, seconds):
    cmd = [ffmpeg, "-hide_banner", "-loglevel", "error", "-nostdin",
           "-ss", f"{seconds:.3f}", "-i", str(video), "-an", "-sn", "-dn",
           "-frames:v", "1", "-f", "image2pipe", "-c:v", "bmp", "-"]
    res = subprocess.run(cmd, capture_output=True)
    if res.returncode != 0 or not res.stdout:
        return None
    return cv2.imdecode(np.frombuffer(res.stdout, np.uint8), cv2.IMREAD_COLOR)


def export_jpg(ffmpeg, video, seconds, destination):
    cmd = [ffmpeg, "-hide_banner", "-loglevel", "error", "-nostdin", "-y",
           "-ss", f"{seconds:.3f}", "-i", str(video), "-an", "-sn", "-dn",
           "-frames:v", "1", "-q:v", "2", str(destination)]
    res = subprocess.run(cmd, capture_output=True, text=True)
    if res.returncode != 0 or not destination.is_file():
        raise RuntimeError(res.stderr.strip()[:300] or "Не удалось сохранить кадр")


class FaceModels:
    def __init__(self, root: Path):
        from insightface.app import FaceAnalysis
        import onnxruntime as ort
        available = ort.get_available_providers()
        providers = ["CoreMLExecutionProvider", "CPUExecutionProvider"] if "CoreMLExecutionProvider" in available else ["CPUExecutionProvider"]
        self.app = FaceAnalysis(name="buffalo_s", root=str(root), providers=providers, allowed_modules=["detection", "recognition", "landmark_3d_68"])
        self.app.prepare(ctx_id=0, det_size=(640, 640), det_thresh=0.5)

    def detect(self, image):
        return self.app.get(image)


def face_crop(image, bbox, size=96):
    h, w = image.shape[:2]
    x1, y1, x2, y2 = bbox[:4]
    cx, cy = (x1 + x2) / 2, (y1 + y2) / 2
    side = max(x2 - x1, y2 - y1) * 1.1
    a = max(0, int(round(cx - side / 2)))
    b = max(0, int(round(cy - side / 2)))
    c = min(w, int(round(cx + side / 2)))
    d = min(h, int(round(cy + side / 2)))
    if c - a < 16 or d - b < 16:
        return None
    crop = cv2.resize(image[b:d, a:c], (size, size), interpolation=cv2.INTER_AREA)
    return cv2.cvtColor(crop, cv2.COLOR_BGR2GRAY)


def run_faces(args):
    from sklearn.cluster import AgglomerativeClustering

    started = time.monotonic()
    video = Path(args.video).expanduser().resolve()
    if not video.is_file():
        raise RuntimeError(f"Файл не найден: {video}")
    ffmpeg = find_tool("ffmpeg", args.ffmpeg)
    ffprobe = find_tool("ffprobe", args.ffprobe)

    progress(0.02, "Читаю видео…")
    info = probe(ffprobe, video)
    models_dir = find_models_dir(args.models)

    progress(0.08, "Загружаю модель анализа лиц…")
    fm = FaceModels(models_dir)

    width = args.analysis_width if info.width >= info.height else int(round(args.analysis_width * info.width / info.height / 2) * 2)
    height = int(round(width * info.height / info.width / 2) * 2)
    effective_dur = min(info.duration, args.max_seconds) if args.max_seconds > 0 else info.duration
    expected = max(int(effective_dur / args.step), 1)
    detections = []
    frames = 0

    def do_scan(hw):
        nonlocal frames
        for index, img in scan_frames(ffmpeg, video, args.step, width, height, hw, max_seconds=args.max_seconds):
            frames = index + 1
            seconds = index * args.step
            for face in fm.detect(img):
                fh = float(face.bbox[3] - face.bbox[1])
                if fh < args.min_face * height:
                    continue
                gray = face_crop(img, face.bbox)
                if gray is None:
                    continue
                sharp = float(cv2.Laplacian(gray, cv2.CV_64F).var())
                mean = float(gray.mean()) / 255.0
                exp_s = clip01(1.0 - abs(mean - 0.5) * 2.0)
                emb = face.normed_embedding.astype(np.float32)
                detections.append(Detection(
                    frame=index, seconds=seconds, bbox=face.bbox.copy(), kps=face.kps.copy(),
                    embedding=emb, height_fraction=fh / height, sharpness=sharp,
                    rough_pose=1.0, exposure=exp_s,
                ))
            if index % 8 == 0:
                progress(STAGE_SCAN * index / expected, f"Анализ лиц: {format_mmss(seconds)} / {format_mmss(effective_dur)}")

    try:
        do_scan(True)
    except RuntimeError:
        if frames == 0:
            do_scan(False)
    if not detections:
        raise RuntimeError("В выбранном фрагменте видео лица не найдены.")

    progress(STAGE_SCAN, "Группирую ведущих и героев…")
    embs = np.stack([d.embedding for d in detections])
    if len(detections) == 1:
        labels = np.array([0])
    else:
        clustering = AgglomerativeClustering(n_clusters=None, distance_threshold=0.95, metric="euclidean", linkage="average")
        labels = clustering.fit_predict(embs)

    groups = {}
    for idx, lbl in enumerate(labels):
        groups.setdefault(int(lbl), []).append(idx)
    people = sorted(groups.values(), key=lambda m: -len(m))[:args.max_persons]

    output = Path(args.output_dir).expanduser() if args.output_dir else video.parent / f"{video.stem}_FrameBoard"
    output.mkdir(parents=True, exist_ok=True)
    for old in list(output.glob("frame_*.jpg")) + [output / "contact_sheet.jpg", output / "report.json"]:
        if old.exists():
            old.unlink()

    effective_gap = min(args.gap, 6.0) if (args.max_seconds > 0 and args.max_seconds <= 90 and args.gap >= 30.0) else args.gap
    result_people = []
    all_sheet_frames = []

    for p_idx, members in enumerate(people, start=1):
        dets = sorted([detections[i] for i in members], key=lambda d: -(d.sharpness * d.height_fraction * d.exposure))
        chosen = []
        for d in dets:
            if all(abs(d.seconds - c.seconds) >= effective_gap for c in chosen):
                chosen.append(d)
                if len(chosen) >= args.per_person:
                    break
        if not chosen:
            chosen = dets[:args.per_person]

        name = f"Герой {p_idx}"
        frame_items = []
        for rank, d in enumerate(sorted(chosen, key=lambda x: x.seconds), start=1):
            ts = format_mmss(d.seconds)
            dest = output / f"frame_p{p_idx}_{rank}_{ts.replace(':', '-')}.jpg"
            progress(STAGE_SCAN + STAGE_SCORE * (p_idx / max(len(people), 1)), f"Сохраняю {name} · кадр {rank}…")
            export_jpg(ffmpeg, video, d.seconds, dest)
            img = cv2.imread(str(dest))
            palette = extract_palette(img, k=5)
            item = {
                "index": len(all_sheet_frames) + 1,
                "seconds": round(d.seconds, 2),
                "duration_sec": 0.0,
                "timestamp": ts,
                "path": str(dest),
                "palette": palette,
                "person": name,
            }
            frame_items.append(item)
            all_sheet_frames.append(item)

        result_people.append({
            "name": name,
            "screen_time_seconds": round(len(members) * args.step, 1),
            "frames": [it["path"] for it in frame_items],
        })

    sheet_path = output / "contact_sheet.jpg"
    build_contact_sheet(all_sheet_frames, sheet_path, f"{video.stem}  |  {len(result_people)} people  |  {len(all_sheet_frames)} hero frames")

    elapsed = time.monotonic() - started
    report = {
        "mode": "faces",
        "video": str(video),
        "video_duration": round(info.duration, 1),
        "elapsed_seconds": round(elapsed, 1),
        "contact_sheet": str(sheet_path) if sheet_path.exists() else None,
        "people": result_people,
        "frames": all_sheet_frames,
    }
    (output / "report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    progress(1.0, "Готово")
    emit(
        "result",
        mode="faces",
        output_dir=str(output),
        report=str(output / "report.json"),
        video_duration=round(info.duration, 1),
        avg_shot_seconds=0.0,
        elapsed_seconds=round(elapsed, 1),
        people=result_people,
        contact_sheet=str(sheet_path) if sheet_path.exists() else None,
        storyboard_frames=all_sheet_frames,
    )


def main():
    parser = argparse.ArgumentParser(description="FrameBoard: стоп-кадры и раскадровка видео")
    parser.add_argument("video")
    parser.add_argument("--mode", choices=["faces", "storyboard"], default="storyboard")
    parser.add_argument("--max-seconds", type=float, default=0.0)
    parser.add_argument("--storyboard-mode", choices=["interval", "scene"], default="scene")
    parser.add_argument("--interval", type=float, default=1.0)
    parser.add_argument("--scene-threshold", type=float, default=0.30)
    parser.add_argument("--max-frames", type=int, default=60)
    parser.add_argument("--step", type=float, default=0.5)
    parser.add_argument("--gap", type=float, default=30.0)
    parser.add_argument("--per-person", type=int, default=3)
    parser.add_argument("--max-persons", type=int, default=6)
    parser.add_argument("--analysis-width", type=int, default=640)
    parser.add_argument("--min-face", type=float, default=0.06)
    parser.add_argument("--models", default="")
    parser.add_argument("--output-dir")
    parser.add_argument("--ffmpeg")
    parser.add_argument("--ffprobe")
    args = parser.parse_args()
    try:
        if args.mode == "faces":
            run_faces(args)
        else:
            run_storyboard(args)
    except Exception as error:
        import traceback
        traceback.print_exc()
        emit("error", message=str(error) or error.__class__.__name__)
        sys.exit(1)


if __name__ == "__main__":
    main()
