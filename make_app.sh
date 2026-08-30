#!/bin/bash
# ============================================================================
# DiskProbe 打包脚本：把 SPM 构建产物组装成标准 .app（双击即可启动）
#
# 用法：
#   ./make_app.sh            # 构建 release + 打包 + 签名
#   ./make_app.sh --debug    # 用 debug 构建（更快，用于测试）
#
# 签名：优先使用钥匙串里的 Apple Development 身份（真实扫描的特权 helper
# 必须真实签名，SMAppService 拒绝 ad-hoc）；找不到则退回 ad-hoc（仅演示扫描）。
#
# 产物：dist/DiskProbe.app
# ============================================================================
set -euo pipefail
cd "$(dirname "$0")"

MODE="${1:---release}"
MODE_NAME="${MODE#--}"
APP_NAME="DiskProbe"
HELPER_NAME="DiskProbeHelper"
DIST_DIR="dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"

# 多架构构建由 xcbuild 接管，产物在 .build/apple/Products/<Release|Debug>；
# 单架构构建产物在 .build/<release|debug>。
# 注意：产物目录必须在 swift build 之后判断——构建前判断会拿到上一次构建的
# 陈旧目录（甚至回退到同样陈旧的 .build/<mode>），静默打出旧二进制。
case "$MODE_NAME" in
    release) XCODE_PROD_DIR=".build/apple/Products/Release" ;;
    debug)   XCODE_PROD_DIR=".build/apple/Products/Debug" ;;
    *)       XCODE_PROD_DIR="" ;;
esac

echo "==> 1/5 构建 ($MODE, Universal 2: arm64 + x86_64)..."
# 多架构构建需要完整版 Xcode 的 xcbuild；装了 Xcode 就优先用它（不影响全局 xcode-select）
if [ -z "${DEVELOPER_DIR:-}" ] && [ -x "/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild" ]; then
    export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi
swift build -c "${MODE#--}" --arch arm64 --arch x86_64

if [ -n "$XCODE_PROD_DIR" ] && [ -f "$XCODE_PROD_DIR/$APP_NAME" ]; then
    BUILD_DIR="$XCODE_PROD_DIR"
else
    BUILD_DIR=".build/${MODE_NAME}"
fi
if [ "$BUILD_DIR/$APP_NAME" -ot "$APP_BUNDLE/Contents/MacOS/$APP_NAME" ] 2>/dev/null; then
    echo "  ⚠️ 警告：新构建的二进制比 dist 里的旧（时钟异常？），继续按新构建打包"
fi
echo "  使用产物：$BUILD_DIR/$APP_NAME"

echo "==> 2/5 组装 .app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"
mkdir -p "$APP_BUNDLE/Contents/Library/LaunchServices"
mkdir -p "$APP_BUNDLE/Contents/Library/LaunchDaemons"

cp "$BUILD_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/"
# SMJobBless（macOS 11/12）硬性要求：helper 文件名 = launchd label
cp "$BUILD_DIR/$HELPER_NAME" "$APP_BUNDLE/Contents/Library/LaunchServices/local.diskprobe.helper"

# Info.plist
cat > "$APP_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>DiskProbe</string>
    <key>CFBundleIdentifier</key><string>local.diskprobe</string>
    <key>CFBundleVersion</key><string>2.9</string>
    <key>CFBundleShortVersionString</key><string>2.9</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>LSMinimumSystemVersion</key><string>11.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>LSUIElement</key><false/>
    <!-- SMJobBless（macOS 11/12）要求：声明本 app 拥有的特权 helper。
         值是 helper 必须满足的签名要求串；与 helper 内嵌 SMAuthorizedClients
         （校验客户端 app）方向相反、互为镜像。13+ 的 SMAppService 不读此键。 -->
    <key>SMPrivilegedExecutables</key>
    <dict>
        <key>local.diskprobe.helper</key>
        <string>identifier "local.diskprobe.helper" and anchor apple generic</string>
    </dict>
</dict>
</plist>
PLIST

# 特权 helper 的 launchd plist（SMAppService daemon）
cat > "$APP_BUNDLE/Contents/Library/LaunchDaemons/local.diskprobe.helper.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>local.diskprobe.helper</string>
    <key>BundleProgram</key><string>Contents/Library/LaunchServices/local.diskprobe.helper</string>
    <key>MachServices</key>
    <dict>
        <key>local.diskprobe.helper</key><true/>
    </dict>
    <key>AssociatedBundleIdentifiers</key>
    <array>
        <string>local.diskprobe</string>
    </array>
    <key>StandardErrorPath</key><string>/tmp/diskprobe-helper.err</string>
    <key>StandardOutPath</key><string>/tmp/diskprobe-helper.out</string>
</dict>
</plist>
PLIST

# 赞赏收款码（可选）：Resources/Donate-WeChat.png、Donate-Alipay.png
for f in Donate-WeChat.png Donate-Alipay.png; do
    [ -f "Resources/$f" ] && cp "Resources/$f" "$APP_BUNDLE/Contents/Resources/"
done

# 应用图标（可选）：用系统图标占位，无则跳过
if [ -f "Resources/AppIcon.icns" ]; then
    cp Resources/AppIcon.icns "$APP_BUNDLE/Contents/Resources/"
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || true
fi

echo "==> 3/5 选择签名身份..."
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk '/Apple Development/{print $2; exit}')"
if [ -n "${IDENTITY:-}" ]; then
    echo "  使用身份：${IDENTITY}（真实扫描可用）"
    SIGN_MODE="real"
else
    echo "  ⚠️ 未找到 Apple Development 身份，退回 ad-hoc 签名（仅演示扫描可用）"
    SIGN_MODE="adhoc"
fi

echo "==> 4/5 签名..."
if [ "$SIGN_MODE" = "real" ]; then
    # 先签 helper，再签 app（外层签名会封存内层）
    codesign --force --sign "$IDENTITY" --timestamp=none \
        --identifier local.diskprobe.helper "$APP_BUNDLE/Contents/Library/LaunchServices/local.diskprobe.helper"
    codesign --force --sign "$IDENTITY" --timestamp=none \
        --identifier local.diskprobe "$APP_BUNDLE"
else
    codesign --force --sign - "$APP_BUNDLE"
fi

echo "==> 5/5 完成"
echo "  应用位置：$APP_BUNDLE"
if [ "$SIGN_MODE" = "real" ]; then
    echo "  真实扫描：首次使用时在 app 内把模式切到「真实」，点「安装特权助手」并输入管理员密码。"
else
    echo "  当前仅提供安全的演示扫描；安装 Apple Development 证书后重新打包即可解锁真实扫描。"
fi
echo
echo "  提示：如果 macOS 提示\"无法打开\"，在终端执行："
echo "    xattr -dr com.apple.quarantine '$APP_BUNDLE'"
