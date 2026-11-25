#!/usr/bin/env bash
# 起一台本机 Android 模拟器，专门用来验证改动 —— 不碰用户的真机。
#
# 为什么用模拟器：
# 1. 真机是用户自己在用的设备，安装会弹窗、会占屏、会打断
# 2. Mac 是 arm64，模拟器也是 arm64-v8a，和项目交叉编译出来的 .so 同架构，
#    所以模拟器里跑的就是真机那份二进制，不是"另编一个版本"
# 3. uiautomator dump 在模拟器上可用（真机 Android 16 上跑不出文件）
#
# 空闲关机：默认闲置 1 小时就自己关机（不是从启动算起，是"最后一次被使用"之后一小时）。
# 每次用 scripts/sim 干活都会刷新这个时间；一直有交互就一直活着。
# 这台机器上没有 Android Studio 帮你管模拟器，忘了关它就会一直空转 CPU、占 2.5GB 内存。
# LIFETIME 可覆盖（秒）。
# 再次运行时，如果发现已经跑超时的实例，先关掉再起。
#
# 用法：
#   scripts/run_emulator.sh                     # 起 default AVD（pili-test），端口 5554
#   PORT=5556 AVD_NAME=其他 scripts/run_emulator.sh
#   LIFETIME=7200 scripts/run_emulator.sh       # 这次给两小时
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SDK="${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}"
AVD="${AVD_NAME:-pili-test}"
PORT="${PORT:-5554}"
LIFETIME="${LIFETIME:-3600}"   # 秒；闲置这么久就关机
STAMP="${TMPDIR:-/tmp}/pili-emulator-$PORT.lastuse"

if [ ! -x "$SDK/emulator/emulator" ]; then
    echo "没装 emulator。先跑：" >&2
    echo "  sdkmanager --install emulator 'system-images;android-35;google_apis;arm64-v8a'" >&2
    exit 1
fi

if [ ! -d "$HOME/.android/avd/$AVD.avd" ]; then
    echo "没有 AVD：${AVD}。创建：" >&2
    echo "  echo no | avdmanager create avd -n $AVD -k 'system-images;android-35;google_apis;arm64-v8a' -d pixel_6" >&2
    exit 1
fi

# BSD ps 没有 etimes（那是 GNU 的），只有 etime，格式 [[dd-]hh:]mm:ss
proc_age_sec() {
    local e p; e=$(ps -o etime= -p "$1" 2>/dev/null | tr -d ' ') || return 0
    [ -z "$e" ] && { echo 0; return; }
    local d=0 h=0 m=0 s=0
    case "$e" in *-*) d=${e%%-*}; e=${e#*-} ;; esac
    local a b c
    IFS=: read -r a b c <<< "$e"
    if [ -z "${c:-}" ]; then m=$a; s=$b; else h=$a; m=$b; s=$c; fi
    echo $(( ${d:-0}*86400 + ${h:-0}*3600 + ${m:-0}*60 + ${s:-0} ))
}

DEV="emulator-$PORT"

# 已经有一台在跑？
if adb devices | awk '{print $1}' | grep -qx "$DEV"; then
    PID=$(pgrep -f "avd $AVD" | head -1 || true)
    ET=0
    if [ -n "${PID:-}" ]; then
        ET=$(proc_age_sec "$PID")
    fi
    # 没有时间戳（旧版本起的、或手敲 emulator 起的）就退回进程年龄
    if [ -f "$STAMP" ]; then
        IDLE=$(( $(date +%s) - $(stat -f%m "$STAMP") ))
    else
        IDLE=$ET
    fi
    if [ "$IDLE" -ge "$LIFETIME" ]; then
        echo "$DEV 已闲置 ${IDLE}s（超过 ${LIFETIME}s），关掉重开"
        adb -s "$DEV" emu kill >/dev/null 2>&1 || true
        sleep 3
    else
        echo "$DEV 已在运行（${ET}s），直接用"
        exit 0
    fi
fi

EMU_LOG="${TMPDIR:-/tmp}/pili-emulator-$PORT.log"
"$SDK/emulator/emulator" -avd "$AVD" \
    -no-window -no-audio -no-boot-anim -no-snapshot \
    -gpu swiftshader_indirect -port "$PORT" >"$EMU_LOG" 2>&1 &

adb -s "$DEV" wait-for-device
echo "等待开机……"
until [ "$(adb -s "$DEV" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ]; do
    sleep 3
done
touch "$STAMP"
echo "$LIFETIME" > "${TMPDIR:-/tmp}/pili-emulator-$PORT.lifetime"
echo "已就绪：${DEV}（之后 scripts/build_android.sh release install 会自动装到这里）"

# 空闲监视交给独立脚本，用 nohup 跑，脚本退出也不受 HUP 影响。
# （原来把循环塞在这个脚本的 subshell 里，管道一返回非零就可能连带自杀，实测不会关机。）
nohup bash "$ROOT/scripts/idle-watch.sh" "$DEV" "$LIFETIME" >/dev/null 2>&1 &
echo "闲置 ${LIFETIME}s 自动关机；用 scripts/sim 干活会自动续命。"
