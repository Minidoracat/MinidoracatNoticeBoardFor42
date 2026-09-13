#!/usr/bin/env python3
"""把服主提供的音檔處理成公告提示音資產（裁切／單聲道／正規化／淡入淡出）。

為什麼要處理而不是直接複製：
  * 長度。通知音是每次公告更新都會響一次的東西，原始素材常常是好幾秒的一整段
    （附帶多個音與殘響）。PZ 自己的 UI 音效全部都在 1 秒以內。
  * 音量。MOD 自帶的音效走非 bank 通道，**不受玩家的音效音量選項影響**
    （理由與出處見 scripts/gen_notify_sound.py 檔頭），所以峰值必須在資產端壓好，
    不能把滿刻度（peak 1.0）的素材原樣丟進去。
  * 邊界。突然切斷會有 click／pop，所以裁切點要補淡入淡出。
  * 聲道。UI 提示音不需要立體聲，轉單聲道直接省一半體積。

這支腳本**不生成**音效內容，只做上述處理；原創的內建音效由 gen_notify_sound.py 生成。
兩者的輸出都必須通過 verify_notify_sound()（同一份規格），那也是 verify_mod.py 的閘門。

用法（在 repo 根）：
    python scripts/prep_notify_sound.py --src ~/Downloads/1583.wav
    python scripts/prep_notify_sound.py --src ~/Downloads/1583.wav --start 3.4 --end 4.5
    python scripts/prep_notify_sound.py --src ... --peak 0.25 --no-mono
輸入支援 16-bit PCM 的 .wav（Python 標準庫只解得了未壓縮 WAV；mp3／ogg 請先自行轉檔）。

語音提示音（MinidoracatNBVoiceCH／EN／JP）也走這支腳本；內容用 fish-audio-tts skill 重生，
台詞與聲音參數留在 scripts/voice_lines.json（CH/CN 共用 CH，JP 另一個聲音）：
    python ~/.claude/skills/fish-audio-tts/scripts/fish_tts.py batch \
        --manifest scripts/voice_lines.json --out-dir temp/voice/regenerated --trim --verify
    python scripts/prep_notify_sound.py --src temp/voice/regenerated/notice_zh.wav \
        --out MOD/MinidoracatNoticeBoardFor42/Contents/mods/MinidoracatNoticeBoardFor42/42/media/sound/MinidoracatNBVoiceCH.wav \
        --no-trim --fade-out 0.02
    # en→EN、ja→JP；保留 TTS 已裁好的 80ms 緩衝，避免二次裁切吃掉輕聲起音。

**版權**：這支腳本不會去取得任何素材，只處理你指定的檔案。放進 MOD 並公開發布前，
請自行確認該音效的授權允許再散布——商業作品（動畫、遊戲）的音效通常不允許。
"""

import argparse
import math
import os
import struct
import sys
import wave

# 資產規格（verify_notify_sound 與 verify_mod.py 的閘門共用這組上下界）。
# 每一條都是「玩家會不會受不了」的硬界，與音效內容無關，所以自訂音檔一樣適用。
MAX_SECONDS = 5.0          # 通知音上限；再長就是背景音樂了（服主自備素材常有殘響尾巴）
MAX_PEAK = 0.60            # 峰值上限（自帶音效不受玩家音量控制，滿刻度會炸耳）
MIN_PEAK = 0.05            # 下限：低到聽不見等於沒有通知
ALLOWED_RATES = (22050, 32000, 44100, 48000)
SAMPLE_WIDTH = 2           # 只收 16-bit PCM
MAX_CHANNELS = 2

DEFAULT_PEAK = 0.32        # 與內建原創音效同一個目標峰值
DEFAULT_FADE_IN = 0.005
DEFAULT_FADE_OUT = 0.15
SILENCE_GATE = 0.02        # 自動修剪頭尾靜音的門檻（相對峰值）

SOUND_NAME = "MinidoracatNBNotify"
# 語音提示音（公告面板的「語音語系」選項，CH/CN 共用 CH）。內容來源與重生指令見
# scripts/voice_lines.json；一樣走這支腳本處理，所以與提示音共用同一組資產規格。
VOICE_SOUND_NAMES = ("MinidoracatNBVoiceCH", "MinidoracatNBVoiceEN", "MinidoracatNBVoiceJP")


def sound_path(name):
    return os.path.join(
        "MOD", "MinidoracatNoticeBoardFor42", "Contents", "mods",
        "MinidoracatNoticeBoardFor42", "42", "media", "sound", name + ".wav",
    )


DEFAULT_OUT = sound_path(SOUND_NAME)
VOICE_OUTS = tuple(sound_path(name) for name in VOICE_SOUND_NAMES)


def read_wav(path):
    with wave.open(path, "rb") as handle:
        channels = handle.getnchannels()
        width = handle.getsampwidth()
        rate = handle.getframerate()
        count = handle.getnframes()
        raw = handle.readframes(count)
    if width != SAMPLE_WIDTH:
        raise SystemExit("只支援 16-bit PCM WAV，來源是 %d-bit" % (width * 8))
    values = struct.unpack("<%dh" % (count * channels), raw)
    return channels, rate, count, values


def to_channels(values, channels, count, mono):
    """回傳 [-1,1] 浮點的 list of frames；mono=True 時混成單聲道。"""
    frames = []
    if channels == 1:
        for i in range(count):
            frames.append((values[i] / 32768.0,))
    else:
        for i in range(count):
            left = values[i * channels] / 32768.0
            right = values[i * channels + 1] / 32768.0
            frames.append(((left + right) / 2.0,) if mono else (left, right))
    return frames


def trim_silence(frames, rate):
    """修掉頭尾低於門檻的部分。回傳 (frames, 起點秒數)。"""
    peak = max(max(abs(v) for v in frame) for frame in frames)
    gate = peak * SILENCE_GATE
    start = 0
    while start < len(frames) and max(abs(v) for v in frames[start]) <= gate:
        start += 1
    stop = len(frames)
    while stop > start and max(abs(v) for v in frames[stop - 1]) <= gate:
        stop -= 1
    return frames[start:stop], start / rate


def apply_fades(frames, rate, fade_in, fade_out):
    total = len(frames)
    fade_in_count = min(int(fade_in * rate), total)
    fade_out_count = min(int(fade_out * rate), total)
    for i in range(fade_in_count):
        gain = i / fade_in_count
        frames[i] = tuple(v * gain for v in frames[i])
    for i in range(fade_out_count):
        gain = i / fade_out_count
        index = total - 1 - i
        frames[index] = tuple(v * gain for v in frames[index])
    return frames


def normalize(frames, target_peak):
    peak = max(max(abs(v) for v in frame) for frame in frames)
    if peak <= 0.0:
        raise SystemExit("來源全是靜音")
    scale = target_peak / peak
    return [tuple(v * scale for v in frame) for frame in frames]


def encode(frames):
    limit = 32767
    out = bytearray()
    for frame in frames:
        for value in frame:
            scaled = value * limit
            quantized = int(math.floor(scaled + 0.5)) if scaled >= 0 \
                else -int(math.floor(-scaled + 0.5))
            quantized = max(-limit, min(limit, quantized))
            out += struct.pack("<h", quantized)
    return bytes(out)


def write_wav(path, frames, rate):
    directory = os.path.dirname(path)
    if directory:
        os.makedirs(directory, exist_ok=True)
    with wave.open(path, "wb") as handle:
        handle.setnchannels(len(frames[0]))
        handle.setsampwidth(SAMPLE_WIDTH)
        handle.setframerate(rate)
        handle.writeframes(encode(frames))


def verify_notify_sound(path):
    """驗證音檔符合資產規格。回傳問題清單（空 = 通過）。

    **刻意不比對內容**：服主可以換成自己的音效（見 docs/ADMIN_GUIDE.md），
    閘門要擋的是「檔案不見／不是引擎讀得懂的格式／長到變背景音樂／大聲到炸耳」，
    而不是「不等於某一份特定的 PCM」。
    """
    problems = []
    if not os.path.isfile(path):
        return ["缺少音效檔: " + path]
    try:
        with wave.open(path, "rb") as handle:
            channels = handle.getnchannels()
            width = handle.getsampwidth()
            rate = handle.getframerate()
            count = handle.getnframes()
            comp = handle.getcomptype()
            raw = handle.readframes(count)
    except Exception as error:
        return ["音效檔無法解析（引擎也讀不了）: %s (%s)" % (path, error)]

    if comp != "NONE":
        problems.append("必須是未壓縮 PCM，實際壓縮型別 " + comp)
    if width != SAMPLE_WIDTH:
        problems.append("必須是 16-bit，實際 %d-bit" % (width * 8))
    if channels < 1 or channels > MAX_CHANNELS:
        problems.append("聲道數必須是 1 或 2，實際 %d" % channels)
    if rate not in ALLOWED_RATES:
        problems.append("取樣率 %d 不在允許清單 %s" % (rate, str(ALLOWED_RATES)))
    if rate > 0 and count / rate > MAX_SECONDS:
        problems.append("長度 %.2f 秒超過上限 %.1f 秒（通知音不是背景音樂）"
                        % (count / rate, MAX_SECONDS))
    if problems:
        return problems   # 格式不對就別再解 PCM

    values = struct.unpack("<%dh" % (count * channels), raw)
    peak = max(abs(v) for v in values) / 32768.0 if values else 0.0
    if peak > MAX_PEAK:
        problems.append("峰值 %.3f 超過上限 %.2f——自帶音效不受玩家音量控制，"
                        "請用 scripts/prep_notify_sound.py 壓低（--peak）" % (peak, MAX_PEAK))
    if peak < MIN_PEAK:
        problems.append("峰值 %.3f 低於下限 %.2f（幾乎聽不見）" % (peak, MIN_PEAK))
    return problems


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--src", required=True, help="來源 16-bit PCM WAV")
    parser.add_argument("--out", default=DEFAULT_OUT, help="輸出路徑")
    parser.add_argument("--start", type=float, default=None, help="裁切起點（秒）")
    parser.add_argument("--end", type=float, default=None, help="裁切終點（秒）")
    parser.add_argument("--max-seconds", type=float, default=MAX_SECONDS,
                        help="長度上限（秒）；預設就是資產規格上限 %.1f，"
                             "也就是**不主動裁切內容**。要縮短請自己給值或用 --start/--end"
                             % MAX_SECONDS)
    parser.add_argument("--peak", type=float, default=DEFAULT_PEAK, help="目標峰值")
    parser.add_argument("--fade-in", type=float, default=DEFAULT_FADE_IN)
    parser.add_argument("--fade-out", type=float, default=DEFAULT_FADE_OUT)
    parser.add_argument("--no-mono", action="store_true", help="保留立體聲")
    parser.add_argument("--no-trim", action="store_true", help="不自動修剪頭尾靜音")
    args = parser.parse_args()

    src = os.path.expanduser(args.src)
    channels, rate, count, values = read_wav(src)
    frames = to_channels(values, channels, count, not args.no_mono)
    source_seconds = len(frames) / rate

    offset = 0.0
    if not args.no_trim and args.start is None and args.end is None:
        frames, offset = trim_silence(frames, rate)

    if args.start is not None or args.end is not None:
        start = int((args.start or 0.0) * rate)
        stop = int(args.end * rate) if args.end is not None else len(frames)
        frames = frames[start:stop]
        offset = args.start or 0.0

    limit = int(args.max_seconds * rate)
    truncated = len(frames) > limit
    if truncated:
        frames = frames[:limit]

    frames = normalize(apply_fades(frames, rate, args.fade_in, args.fade_out), args.peak)
    write_wav(args.out, frames, rate)

    problems = verify_notify_sound(args.out)
    print("來源 %s：%dch %dHz %.3fs" % (os.path.basename(src), channels, rate, source_seconds))
    print("輸出 %s" % args.out)
    print("  取用 %.2fs 起、長 %.2fs%s、%s、峰值 %.3f"
          % (offset, len(frames) / rate, "（已截到上限）" if truncated else "",
             "單聲道" if len(frames[0]) == 1 else "立體聲", args.peak))
    if problems:
        for problem in problems:
            print("  FAIL " + problem)
        return 1
    print("  規格檢查通過（verify_notify_sound）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
