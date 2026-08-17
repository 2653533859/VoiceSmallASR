#!/usr/bin/env bash
set -euo pipefail

apk_path=${1:?用法：android_apk_install_smoke.sh <apk> [device-serial]}
device_serial=${2:-${VSASR_ANDROID_DEVICE:-emulator-5554}}
adb_bin=${ADB_BIN:-adb}
package_name=${VSASR_ANDROID_PACKAGE:-com.voicesmallasr.vsasr_app}
startup_wait_seconds=${VSASR_ANDROID_STARTUP_WAIT_SECONDS:-8}

if [[ ! -f "$apk_path" ]]; then
  echo "APK 不存在：$apk_path" >&2
  exit 1
fi

"$adb_bin" start-server >/dev/null
"$adb_bin" -s "$device_serial" wait-for-device

cleanup() {
  "$adb_bin" -s "$device_serial" shell am force-stop "$package_name" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# 清除旧应用数据，避免把已有配置误当成首次启动结果。
"$adb_bin" -s "$device_serial" shell pm clear "$package_name" >/dev/null 2>&1 || true
"$adb_bin" -s "$device_serial" install -r "$apk_path"

version_line=$("$adb_bin" -s "$device_serial" shell dumpsys package "$package_name" |
  tr -d '\r' | grep -m1 'versionName=' || true)
if [[ -z "$version_line" ]]; then
  echo "安装后无法读取 Android 包版本：$package_name" >&2
  exit 1
fi

"$adb_bin" -s "$device_serial" shell am force-stop "$package_name"
"$adb_bin" -s "$device_serial" shell am start -W -n "$package_name/.MainActivity" >/dev/null

pid=""
for _ in {1..20}; do
  pid=$("$adb_bin" -s "$device_serial" shell pidof "$package_name" |
    tr -d '\r' | awk 'NF { print $1; exit }')
  if [[ -n "$pid" ]]; then
    break
  fi
  sleep 1
done

if [[ -z "$pid" ]]; then
  echo "Android release APK 启动后未发现进程：$package_name" >&2
  exit 1
fi

sleep "$startup_wait_seconds"
pid_after_wait=$("$adb_bin" -s "$device_serial" shell pidof "$package_name" |
  tr -d '\r' | awk 'NF { print $1; exit }')
if [[ -z "$pid_after_wait" ]]; then
  echo "Android release APK 启动后 ${startup_wait_seconds}s 内退出：$package_name" >&2
  exit 1
fi

echo "Android release APK 安装并冷启动通过：设备=${device_serial}，${version_line}，PID=${pid_after_wait}，稳定运行=${startup_wait_seconds}s"
