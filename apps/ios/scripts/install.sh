#!/bin/bash
# Build and install Hako with the signing configuration saved in Xcode.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$ROOT/../.." && pwd)"
DIST="$REPO_ROOT/dist/ios"
DEVICE=""
LIST_ONLY=0
BUILD_ONLY=0
LAUNCH=1
usage() {
    cat <<'HELP'
用法：./scripts/install.sh [选项]
  --device <名称或UDID>  指定已配对 iPhone；仅一台连接时自动选择
  --list                列出已配对 iPhone，不编译或安装
  --build-only          只编译签名，不安装
  --no-launch           安装后不打开 App
  -h, --help            显示帮助

首次请在 Xcode 中登录开发者账号、设置 Team，并成功运行一次。
iPhone 需要信任本机、开启开发者模式并解锁。
日志：build/install/build.log；增量编译缓存：build/install/DerivedData
HELP
}
while [[ $# -gt 0 ]]; do
    case "$1" in
        --device)
            [[ $# -ge 2 && -n "$2" ]] || { echo '错误：--device 需要名称或 UDID。' >&2; exit 2; }
            DEVICE="$2"; shift 2 ;;
        --list) LIST_ONLY=1; shift ;;
        --build-only) BUILD_ONLY=1; shift ;;
        --no-launch) LAUNCH=0; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "未知参数：$1" >&2; usage; exit 2 ;;
    esac
done
for tool in xcrun xcodebuild python3; do
    command -v "$tool" >/dev/null || { echo "缺少工具：$tool，请安装并选择完整 Xcode。" >&2; exit 1; }
done
WORK="$ROOT/build/install"
mkdir -p "$WORK"
# Prevent simultaneous builds/installations sharing this output directory.
if ! mkdir "$WORK/.lock" 2>/dev/null; then
    echo "已有安装任务运行。若上次被强制终止，确认没有任务后删除 $WORK/.lock 再试。" >&2
    exit 1
fi
TEMP="$(mktemp -d "${TMPDIR:-/tmp}/hako-install.XXXXXX")"
trap 'rm -rf "$TEMP"; rmdir "$WORK/.lock"' EXIT

if ! xcrun devicectl list devices --timeout 30 --json-output "$TEMP/devices.json" > "$WORK/devices.log" 2>&1; then
    cat "$WORK/devices.log" >&2
    echo '无法读取设备。请连接并解锁 iPhone，确认已信任本机。' >&2
    exit 1
fi
python3 - "$TEMP/devices.json" "$DEVICE" "$LIST_ONLY" > "$TEMP/selected" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    devices = json.load(f).get('result', {}).get('devices', [])
phones = [d for d in devices if d.get('hardwareProperties', {}).get('deviceType') == 'iPhone'
          and d.get('connectionProperties', {}).get('pairingState') == 'paired']
def name(d): return d.get('deviceProperties', {}).get('name', 'iPhone')
def udid(d): return d.get('hardwareProperties', {}).get('udid', '')
def connected(d): return d.get('connectionProperties', {}).get('tunnelState') == 'connected'
def show():
    for d in phones:
        print(f"{name(d)}  {udid(d)}  {'已连接' if connected(d) else '未连接'}", file=sys.stderr)
if sys.argv[3] == '1':
    show()
    if not phones: print('未发现已配对 iPhone。', file=sys.stderr)
    sys.exit(0)
selector = sys.argv[2]
if selector:
    selected = [d for d in phones if selector in (name(d), udid(d), d.get('identifier'))]
else:
    selected = [d for d in phones if connected(d)]
if len(selected) != 1:
    show()
    print('无法确定唯一目标。请连接 iPhone，或使用 --device "设备名称或UDID" 指定。', file=sys.stderr)
    sys.exit(1)
d = selected[0]
if not udid(d):
    sys.exit('设备没有 UDID，请重新连接。')
if d.get('deviceProperties', {}).get('developerModeStatus') != 'enabled':
    sys.exit('请先在 iPhone 设置 → 隐私与安全性中开启开发者模式。')
print(udid(d))
print(f'目标设备：{name(d)}', file=sys.stderr)
PY
[[ "$LIST_ONLY" -eq 0 ]] || exit 0
TARGET="$(cat "$TEMP/selected")"
BUILT_APP="$WORK/DerivedData/Build/Products/Debug-iphoneos/Hako.app"
APP="$DIST/Hako.app"
echo '正在编译并签名…'
if ! xcodebuild -project "$ROOT/Hako.xcodeproj" -scheme Hako -configuration Debug \
    -destination "platform=iOS,id=$TARGET" -derivedDataPath "$WORK/DerivedData" \
    -allowProvisioningUpdates build > "$WORK/build.log" 2>&1; then
    tail -n 70 "$WORK/build.log" >&2
    echo "编译失败。完整日志：$WORK/build.log" >&2
    echo '签名错误请检查 Xcode 账号、Team 及 App and Website Usage 描述文件权限。' >&2
    exit 1
fi
[[ -d "$BUILT_APP" ]] || { echo "找不到编译产物：$BUILT_APP" >&2; exit 1; }
mkdir -p "$DIST"
[[ "$APP" == "$REPO_ROOT/dist/ios/Hako.app" && ! -L "$REPO_ROOT/dist" && ! -L "$DIST" && ! -L "$APP" ]] || { echo '发布路径无效。' >&2; exit 1; }
if [[ -e "$APP" ]]; then rm -rf -- "$APP"; fi
ditto "$BUILT_APP" "$APP"
codesign --verify --deep --strict "$APP"
if [[ "$BUILD_ONLY" -eq 1 ]]; then
    echo "编译签名成功：$APP"
    exit 0
fi
echo '正在安装到 iPhone…'
if ! xcrun devicectl device install app --device "$TARGET" "$APP" --timeout 120; then
    echo '安装失败，请解锁 iPhone，检查连接、信任及签名配置后重试。' >&2
    exit 1
fi
if [[ "$LAUNCH" -eq 1 ]]; then
    if ! xcrun devicectl device process launch --device "$TARGET" --terminate-existing me.stackli.hako --timeout 30; then
        echo '安装已成功，但自动打开失败。请解锁手机后手动打开 Hako。' >&2
        exit 1
    fi
fi
echo 'Hako 安装完成。'
