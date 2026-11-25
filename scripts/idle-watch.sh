#!/usr/bin/env bash
# 监视一台模拟器：闲置超过 LIFETIME 秒就关机，释放宿主机资源。
# 由 run_emulator.sh 用 nohup 托管，脚本退出也照样计时。
#
#   idle-watch.sh emulator-5554 3600
#
# "闲置" = 距离最后一次 scripts/sim 刷新时间戳的时长，不是从开机算起。
set -u
DEV="${1:?设备名}"
LIFETIME="${2:-3600}"
STAMP="${TMPDIR:-/tmp}/pili-emulator-${DEV##*-}.lastuse"
LOG="${TMPDIR:-/tmp}/pili-emulator-${DEV##*-}.idle.log"

alive() {
    adb devices 2>/dev/null | awk '{print $1}' | grep -qx "$DEV"
}

while :; do
    sleep 20
    if ! alive; then
        echo "$(date +%H:%M:%S) ${DEV} 不在线，监视结束" >>"$LOG"
        exit 0
    fi
    LAST=$(stat -f%m "$STAMP" 2>/dev/null) || LAST=""
    if [ -z "$LAST" ] || [ "$LAST" -eq 0 ] 2>/dev/null; then
        LAST=$(date +%s)   # 没有时间戳就当"刚刚用过"
    fi
    IDLE=$(( $(date +%s) - LAST ))
    if [ "$IDLE" -ge "$LIFETIME" ]; then
        echo "$(date +%H:%M:%S) 闲置 ${IDLE}s ≥ ${LIFETIME}s，关机" >>"$LOG"
        adb -s "$DEV" emu kill >/dev/null 2>&1
        exit 0
    fi
done
