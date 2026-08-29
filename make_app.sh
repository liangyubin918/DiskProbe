#!/bin/bash
# ============================================================================
# DiskProbe 打包脚本：把 SPM 构建产物组装成标准 .app（双击即可启动）
#
# 用法：
#   ./make_app.sh            # 构建 release + 打包 + 自签名
#   ./make_app.sh --debug    # 用 debug 构建（更快，用于测试）
#
# 产物：dist/DiskProbe.app
# ============================================================================
set -euo pipefail
cd "$(dirname "$0")"

MODE="${1:---release}"
BUILD_DIR=".build/${MODE#--}"
APP_NAME="DiskProbe"
DIST_DIR="dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"

echo "==> 1/4 构建 ($MODE)..."
swift build -c "${MODE#--}"

echo "==> 2/4 组装 .app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# 仅打包主程序。真实裸设备读取需使用经系统安装、签名校验的 XPC privileged helper，
# 绝不将可由当前用户修改的 helper 随 app bundle 打包后再请求 root 执行。
cp "$BUILD_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/"

# Info.plist
cat > "$APP_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>DiskProbe</string>
    <key>CFBundleIdentifier</key><string>local.diskprobe</string>
    <key>CFBundleVersion</key><string>1.0</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>LSUIElement</key><false/>
</dict>
</plist>
PLIST

# 应用图标（可选）：用系统图标占位，无则跳过
if [ -f "Resources/AppIcon.icns" ]; then
    cp Resources/AppIcon.icns "$APP_BUNDLE/Contents/Resources/"
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || true
fi

echo "==> 3/4 签名（ad-hoc，自用无需 Developer ID）..."
codesign --force --deep --sign - "$APP_BUNDLE"

echo "==> 4/4 完成"
echo "  应用位置：$APP_BUNDLE"
echo "  双击启动即可（当前版本仅提供安全的演示扫描；真实裸设备读取待特权 XPC helper 完成后开放）。"
echo
echo "  提示：如果 macOS 提示\"无法打开\"，在终端执行："
echo "    xattr -dr com.apple.quarantine '$APP_BUNDLE'"
