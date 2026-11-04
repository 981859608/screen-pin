#!/bin/sh
# 构建 ScreenPin。产物路径和 bundle id 不能变：屏幕录制权限是按 bundle 身份记账的。
# 签名身份用 make-cert.sh 生成的自签证书，这样重新构建（哈希变了）也不会掉录屏授权。
# 用法:  sh build.sh          仅构建
#        sh build.sh --run    构建后打开
#        sh build.sh --regrant 构建后清掉旧的屏幕录制授权（重编后签名变了、画面变成壁纸时用）
set -e
cd "$(dirname "$0")"

APP=build/ScreenPin.app
BUNDLE_ID=com.wangsen.screenpin
SIGN_ID="ScreenPin Local"

# 旧实例还占着同一个 bundle 身份，构建前不退出就会出现"用的是没授权的旧进程"的假象。
if pgrep -f "$APP/Contents/MacOS/ScreenPin" >/dev/null; then
	pkill -f "$APP/Contents/MacOS/ScreenPin" || true
	sleep 1
	echo "已退出旧的 ScreenPin 实例"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -swift-version 5 \
	-framework AppKit -framework AVFoundation -framework CoreImage -framework ScreenCaptureKit \
	-o "$APP/Contents/MacOS/ScreenPin" src/main.swift

cp src/Info.plist "$APP/Contents/Info.plist"
if security find-identity -p codesigning 2>/dev/null | grep -q "\"$SIGN_ID\""; then
	codesign --force --deep -s "$SIGN_ID" "$APP"
else
	echo "警告: 没有签名身份 $SIGN_ID，改用临时签名。这样每次重新构建都会掉录屏授权，建议先跑 sh make-cert.sh。" >&2
	codesign --force --deep -s - "$APP"
fi

echo "构建完成: $(pwd)/$APP"

if [ "$1" = "--regrant" ]; then
	tccutil reset ScreenCapture "$BUNDLE_ID" || true
	echo "已清除旧授权。打开后按提示在 系统设置 → 隐私与安全性 → 屏幕与系统音频录制 里重新勾选。"
elif [ "$1" = "--run" ]; then
	open "$APP"
fi
