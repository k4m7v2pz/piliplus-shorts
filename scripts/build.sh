#!/bin/bash
# 一键构建：敏感检查 → Mac → Android → 安装手机 → 重启Mac
set -e
cd "$(dirname "$0")/../"
export https_proxy=http://127.0.0.1:7890 http_proxy=http://127.0.0.1:7890

echo "=== [1/5] 敏感信息检查 ==="
git add -A
CHANGED=$(git diff --cached --name-only)
if echo "$CHANGED" | grep -qiE '\.(pem|key|p12|keystore)|id_rsa|credentials|secrets'; then
  echo "!!! 检测到敏感文件，终止"
  exit 1
fi
# 检查 staged 内容里有没有公网IP/密钥
if git diff --cached | grep -qE '([0-9]{1,3}\.){3}[0-9]{1,3}'; then
  echo "!!! 检测到IP地址，请确认不是VPS/内网地址"
fi
echo "通过"

echo "=== [2/5] 构建 Mac ==="
fvm flutter build macos --release 2>&1 | tail -1
cd build/macos/Build/Products/Release
mv -f PiliPlus.app "PiliPlus Shorts.app" 2>/dev/null || true
cd -

echo "=== [3/5] 构建 Android ==="
fvm flutter build apk --release 2>&1 | tail -1

echo "=== [4/5] 安装到手机 ==="
ADB_DEVICE=$(adb devices | grep -v "List" | grep "device$" | head -1 | awk '{print $1}')
if [ -n "$ADB_DEVICE" ]; then
  adb -s "$ADB_DEVICE" install -r build/app/outputs/flutter-apk/app-release.apk 2>&1 | tail -1
  adb -s "$ADB_DEVICE" shell appops set com.example.piliplus android:write_settings allow 2>/dev/null
  echo "已安装到 $ADB_DEVICE"
else
  echo "未发现 ADB 设备，跳过"
fi

echo "=== [5/5] 重启 Mac app ==="
pkill -9 -f PiliPlus 2>/dev/null || true
sleep 1
open "build/macos/Build/Products/Release/PiliPlus Shorts.app"

echo "=== 完成 ==="
