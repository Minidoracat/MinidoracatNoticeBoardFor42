#!/usr/bin/env python3
"""新公告提示音的程序化生成器（無第三方依賴，逐位元組確定性）。

這是**原創的備援音效**：不需要任何素材就能生出一顆可用的提示音，
也是「不想用（或不能用）外部音檔」時的預設選擇。
出貨音檔目前由服主自備並經 scripts/prep_notify_sound.py 處理，兩者輸出同一個路徑
（DEFAULT_OUT），彼此覆蓋；verify_mod.py 第 14 項驗的是
prep_notify_sound.verify_notify_sound 的**資產規格**，不綁定內容，所以兩條路都過得了。

特性：
  * 零素材、零版權問題（純數學合成，商業作品的音效不能放進要公開發布的 MOD）。
  * 可重現：純函式、無亂數，重跑兩次得到逐位元組相同的 WAV。
  * 可調：想改音高／長度／音量就改常數，不必回去找素材。

音色設計（目標是「有新東西出現」的明亮提示感，而不是操作回饋的一聲響）：
  A5 -> C#6 -> E6 -> A6 的上升琶音（A 大三和弦加八度），每個音都是
  「基音 + 兩個諧波 + 一個非諧分量」的指數衰減正弦。非諧分量（4.2 倍）是鐘琴／
  glockenspiel 之類敲擊金屬的特徵，少量加入就有金屬清脆感；沒有它會像電子嗶聲。

引擎側的事實（決定了下面幾個常數，出處寫在 AGENTS.md 的 API 表）：
  * GameSounds.getSound() 找不到 FMOD event 時會探測 media/sound/<name>.ogg 再 .wav
    （GameSounds.java:95-137），所以檔名就是 Lua 端 playUISound 用的名字，
    且**只能放在 media/sound/ 正下方**（那個 fallback 沒有子目錄）。
  * 非 bank 音效掛在 FMOD channel group "InGameNonBank"
    （FMODSoundEmitter.java:977、FMODManager.java:156），因此**不經玩家「音效音量」那條
    VCA**：那個選項只設 vca:/Settings_Sfx（SoundManager.java:783-790），而 VCA 只作用於
    FMOD Studio event 音效。
  * channel 音量本身每幀有設，但因子全是 1.0：FileSound.tick 設成
    emitter volume x clip.volume x gameSound.userVolume（FMODSoundEmitter.java:1242 ->
    :1559-1562 -> GameSoundClip.java:68-70），而 playClip 固定傳 1.0（:495-498）、
    non-bank fallback 建的 clip 用預設 volume 1.0（GameSoundClip.java:18）、
    getUserVolume() 需要 enableAdvancedSoundOptions 而該旗標全庫沒有任何呼叫點設 true
    （SystemDisabler.java:20,67-72；MainOptions.lua:2130 的逐音效音量 UI 因此永不顯示）。
  * 兩點合起來 = 這份音檔的振幅就是**音量基準**，所以峰值要自己壓低：PEAK 取 0.32
    而不是接近 1.0。執行期的音量與開關在玩家手上（NBOptions，遊戲的「選項 -> MODS」分頁；
    實作是對 playUISound 回傳的 instance ref 呼叫 getUIEmitter():setVolume），
    沙盒 NotifySound 是服主端總開關——但兩者都是**乘在這個基準上**，基準本身太大聲時
    玩家只能靠調低來補救。
"""

import argparse
import math
import os
import struct
import sys
import wave

SAMPLE_RATE = 44100
CHANNELS = 1
SAMPLE_WIDTH = 2  # 16-bit PCM

# 上升琶音的音高（Hz）與起音時間（秒）。最後一個音拖長，收尾才不會像被切斷。
NOTES = (
    (880.00, 0.000, 0.26),   # A5
    (1108.73, 0.070, 0.26),  # C#6
    (1318.51, 0.140, 0.30),  # E6
    (1760.00, 0.210, 0.46),  # A6
)
# 諧波：(倍率, 相對振幅)。4.2 倍是刻意的非諧分量（金屬敲擊感）。
PARTIALS = ((1.0, 1.0), (2.0, 0.34), (3.0, 0.11), (4.2, 0.07))
ATTACK = 0.004      # 起音斜坡：避免第一個取樣點的 DC 跳變爆音
TAIL = 0.06         # 尾端淡出長度
PEAK = 0.32         # 最終峰值（full scale 的比例）；理由見檔頭
TOTAL = 0.70        # 總長（秒）

SOUND_NAME = "MinidoracatNBNotify"
DEFAULT_OUT = os.path.join(
    "MOD", "MinidoracatNoticeBoardFor42", "Contents", "mods",
    "MinidoracatNoticeBoardFor42", "42", "media", "sound", SOUND_NAME + ".wav",
)


def render():
    """回傳 [-1, 1] 之間的浮點取樣陣列。純函式，無亂數。"""
    total_samples = int(SAMPLE_RATE * TOTAL)
    samples = [0.0] * total_samples

    for frequency, start, decay in NOTES:
        start_index = int(start * SAMPLE_RATE)
        for index in range(start_index, total_samples):
            t = (index - start_index) / SAMPLE_RATE
            envelope = math.exp(-t / decay)
            # 先判斷「衰減是否已經耗盡」再套起音斜坡：順序顛倒的話 t=0 時
            # envelope 被斜坡乘成 0，立刻命中這個 break，整個音一個取樣都不寫。
            if envelope < 1e-5:
                break
            if t < ATTACK:
                envelope *= t / ATTACK
            value = 0.0
            for ratio, amplitude in PARTIALS:
                value += amplitude * math.sin(2.0 * math.pi * frequency * ratio * t)
            samples[index] += value * envelope

    # 全曲尾端淡出，收尾不留階梯
    tail_samples = int(TAIL * SAMPLE_RATE)
    for offset in range(tail_samples):
        index = total_samples - tail_samples + offset
        samples[index] *= 1.0 - offset / tail_samples

    # 正規化到固定峰值：先量到實際峰值再等比縮放，改音高／諧波時音量不會跟著亂跑
    loudest = max(abs(value) for value in samples)
    scale = PEAK / loudest
    return [value * scale for value in samples]


def encode(samples):
    """浮點取樣 -> 16-bit PCM bytes。四捨五入用 floor(x+0.5) 以避開 banker's rounding。"""
    limit = 32767
    frames = bytearray()
    for value in samples:
        scaled = value * limit
        quantized = int(math.floor(scaled + 0.5)) if scaled >= 0 else -int(math.floor(-scaled + 0.5))
        if quantized > limit:
            quantized = limit
        elif quantized < -limit:
            quantized = -limit
        frames += struct.pack("<h", quantized)
    return bytes(frames)


def write_wav(path, frames):
    directory = os.path.dirname(path)
    if directory:
        os.makedirs(directory, exist_ok=True)
    with wave.open(path, "wb") as handle:
        handle.setnchannels(CHANNELS)
        handle.setsampwidth(SAMPLE_WIDTH)
        handle.setframerate(SAMPLE_RATE)
        handle.writeframes(frames)


def verify_sound(path):
    """驗證磁碟上的音檔就是這份參數生成的結果。回傳問題清單（空 = 通過）。

    **這不是 verify_mod.py 的閘門**（那一項驗的是資產規格，見
    prep_notify_sound.verify_notify_sound）。這個函式只回答一個很窄的問題：
    「磁碟上那顆音檔是不是這份參數生出來的原創版？」——改完常數後確認自己有重跑，
    或想知道現在裝的是原創版還是服主自備的音檔時用它。
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
            frames = handle.readframes(count)
    except Exception as error:  # wave 對壞檔會拋各種例外，一律當成驗證失敗
        return ["音效檔無法解析: " + path + " (" + str(error) + ")"]

    if channels != CHANNELS:
        problems.append("聲道數應為 %d，實際 %d" % (CHANNELS, channels))
    if width != SAMPLE_WIDTH:
        problems.append("取樣位元應為 %d bytes，實際 %d" % (SAMPLE_WIDTH, width))
    if rate != SAMPLE_RATE:
        problems.append("取樣率應為 %d，實際 %d" % (SAMPLE_RATE, rate))

    expected = encode(render())
    if frames != expected:
        problems.append(
            "PCM 內容與 gen_notify_sound.py 的生成結果不符"
            "（磁碟 %d bytes / 生成 %d bytes）；改過參數就重跑腳本，"
            "換過音檔請確認來源可再散布" % (len(frames), len(expected))
        )
    return problems


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", default=DEFAULT_OUT, help="輸出的 WAV 路徑")
    parser.add_argument("--verify", action="store_true", help="只驗證，不寫檔")
    args = parser.parse_args()

    if args.verify:
        problems = verify_sound(args.out)
        for problem in problems:
            print("FAIL " + problem)
        return 1 if problems else 0

    samples = render()
    frames = encode(samples)
    write_wav(args.out, frames)
    peak = max(abs(value) for value in samples)
    rms = math.sqrt(sum(value * value for value in samples) / len(samples))
    print("wrote %s" % args.out)
    print("  %.2f s / %d Hz / %d ch / %d bytes PCM"
          % (len(samples) / SAMPLE_RATE, SAMPLE_RATE, CHANNELS, len(frames)))
    print("  peak %.3f  rms %.4f  (sound name: %s)" % (peak, rms, SOUND_NAME))
    return 0


if __name__ == "__main__":
    sys.exit(main())
