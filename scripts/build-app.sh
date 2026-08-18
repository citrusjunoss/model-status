#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
BUILD_DIR="$ROOT_DIR/build"
SIGNING_IDENTITY="${MODEL_STATUS_SIGN_IDENTITY:-InputStatus Local Signing}"
USING_DEFAULT_SIGNING_IDENTITY=$([[ -z "${MODEL_STATUS_SIGN_IDENTITY:-}" ]] && print 1 || print 0)
DEFAULT_KEYCHAIN="$(security default-keychain -d user | sed -E 's/^[[:space:]]*\"//; s/\"[[:space:]]*$//')"
SIGNING_KEYCHAIN="${MODEL_STATUS_SIGNING_KEYCHAIN:-$DEFAULT_KEYCHAIN}"
BUILD_MODE="${1:-all}"
case "$BUILD_MODE" in
    all)
        TARGETS=(intel arm64)
        ;;
    --intel|intel|x86_64)
        TARGETS=(intel)
        ;;
    --arm64|arm64)
        TARGETS=(arm64)
        ;;
    *)
        print -u2 "未知构建模式：$BUILD_MODE（支持 all、--intel、--arm64）"
        exit 2
        ;;
esac
ICONSET_DIR="$BUILD_DIR/AppIcon.iconset"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
MODULE_CACHE_DIR="$BUILD_DIR/module-cache"

IDENTITY_LIST=""
IDENTITY_LINE=""
SIGNING_IDENTITY_HASH="$SIGNING_IDENTITY"
IS_DEVELOPER_ID=0
IS_ADHOC=0
if [[ "$SIGNING_IDENTITY" == "-" ]]; then
    IS_ADHOC=1
else
    IDENTITY_LIST="$(security find-identity -v -p codesigning "$SIGNING_KEYCHAIN")"
    if [[ "$SIGNING_IDENTITY" =~ ^[0-9A-Fa-f]{40}$ ]]; then
        IDENTITY_LINE="$(print -r -- "$IDENTITY_LIST" | /usr/bin/grep -i -F "$SIGNING_IDENTITY" | /usr/bin/head -n 1 || true)"
    else
        IDENTITY_LINE="$(print -r -- "$IDENTITY_LIST" | /usr/bin/grep -F "\"$SIGNING_IDENTITY\"" | /usr/bin/head -n 1 || true)"
    fi
    if [[ -z "$IDENTITY_LINE" ]]; then
        if (( USING_DEFAULT_SIGNING_IDENTITY )); then
            LEGACY_IDENTITY_LINE="$(print -r -- "$IDENTITY_LIST" | /usr/bin/grep -F '"ModelStatus Local Signing"' | /usr/bin/head -n 1 || true)"
            if [[ -n "$LEGACY_IDENTITY_LINE" ]]; then
                SIGNING_IDENTITY="ModelStatus Local Signing"
                IDENTITY_LINE="$LEGACY_IDENTITY_LINE"
            fi
        fi
    fi
    if [[ -z "$IDENTITY_LINE" ]]; then
        print -u2 "未找到有效签名证书：$SIGNING_IDENTITY"
        print -u2 "请先运行：$ROOT_DIR/scripts/setup-signing.sh，或使用 MODEL_STATUS_SIGN_IDENTITY=- 进行临时 ad-hoc 签名。"
        exit 2
    fi
    SIGNING_IDENTITY_HASH="$(print -r -- "$IDENTITY_LINE" | /usr/bin/awk '{ print $2 }')"
    if [[ "$SIGNING_IDENTITY" == Developer\ ID\ Application:* ]]; then
        IS_DEVELOPER_ID=1
    fi
fi

mkdir -p "$BUILD_DIR" "$MODULE_CACHE_DIR"

CLANG_MODULE_CACHE_PATH="$MODULE_CACHE_DIR" \
SWIFT_MODULECACHE_PATH="$MODULE_CACHE_DIR" \
swift "$ROOT_DIR/Tools/generate-icon.swift" "$ICONSET_DIR"

for TARGET in "${TARGETS[@]}"; do
    if [[ "$TARGET" == "intel" ]]; then
        ARCH="x86_64"
        APP_DIR="$ROOT_DIR/dist/InputStatus-intel.app"
    else
        ARCH="arm64"
        APP_DIR="$ROOT_DIR/dist/InputStatus-arm64.app"
    fi
    CONTENTS_DIR="$APP_DIR/Contents"
    MACOS_DIR="$CONTENTS_DIR/MacOS"
    RESOURCES_DIR="$CONTENTS_DIR/Resources"
    mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
    cp "$ROOT_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
    cp "$ICONSET_DIR/icon_512x512@2x.png" "$RESOURCES_DIR/AppIcon.png"

    xcrun --sdk macosx swiftc \
        -Osize \
        -whole-module-optimization \
        -parse-as-library \
        -target "$ARCH-apple-macosx13.0" \
        -sdk "$SDK_PATH" \
        -module-cache-path "$MODULE_CACHE_DIR" \
        -framework AppKit \
        "$ROOT_DIR/Sources/ModelStatus/main.swift" \
        -o "$BUILD_DIR/ModelStatus-$ARCH"
    cp "$BUILD_DIR/ModelStatus-$ARCH" "$MACOS_DIR/ModelStatus"
    strip -x "$MACOS_DIR/ModelStatus"
    CODESIGN_ARGS=(--force --deep --sign "$SIGNING_IDENTITY_HASH")
    if (( ! IS_ADHOC )); then
        CODESIGN_ARGS+=(--keychain "$SIGNING_KEYCHAIN")
    fi
    if (( IS_DEVELOPER_ID )); then
        CODESIGN_ARGS+=(--options runtime --timestamp)
    else
        CODESIGN_ARGS+=(--timestamp=none)
    fi
    codesign "${CODESIGN_ARGS[@]}" "$APP_DIR"

    echo "$APP_DIR"
done
