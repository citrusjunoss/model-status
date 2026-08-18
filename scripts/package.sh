#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
INFO_PLIST="$ROOT_DIR/Resources/Info.plist"
BUILD_SCRIPT="$ROOT_DIR/scripts/build-app.sh"
DIST_DIR="$ROOT_DIR/dist"

usage() {
    cat <<'EOF'
用法：
  ./scripts/package.sh                 升级 patch 版本并打包 Intel + Apple Silicon
  ./scripts/package.sh --bump minor    升级 minor 版本并打包
  ./scripts/package.sh --bump major    升级 major 版本并打包
  ./scripts/package.sh --version 2.3.0 使用指定版本并打包
  ./scripts/package.sh --no-bump        保持当前版本，仅重新打包
  MODEL_STATUS_SIGN_IDENTITY=- ./scripts/package.sh  使用 ad-hoc 签名（适合 GitHub Actions）
EOF
}

read_plist() {
    /usr/libexec/PlistBuddy -c "Print :$1" "$INFO_PLIST"
}

write_plist() {
    /usr/libexec/PlistBuddy -c "Set :$1 $2" "$INFO_PLIST"
}

increment_version() {
    local current="$1" kind="$2"
    local major minor patch
    if [[ "$current" != <->.<->.<-> ]]; then
        print -u2 "版本号不是标准的 major.minor.patch：$current"
        exit 2
    fi
    major="${current%%.*}"
    minor="${current#*.}"; minor="${minor%%.*}"
    patch="${current##*.}"
    case "$kind" in
        major) (( major += 1 )); minor=0; patch=0 ;;
        minor) (( minor += 1 )); patch=0 ;;
        patch) (( patch += 1 )) ;;
        *) print -u2 "不支持的升级类型：$kind"; exit 2 ;;
    esac
    print "$major.$minor.$patch"
}

MODE="patch"
VERSION=""
NO_BUMP=0
while (( $# > 0 )); do
    case "$1" in
        --bump)
            [[ $# -ge 2 ]] || { usage; exit 2; }
            MODE="$2"; shift 2 ;;
        --version)
            [[ $# -ge 2 ]] || { usage; exit 2; }
            VERSION="$2"; shift 2 ;;
        --no-bump)
            NO_BUMP=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) print -u2 "未知参数：$1"; usage; exit 2 ;;
    esac
done

CURRENT_VERSION="$(read_plist CFBundleShortVersionString)"
if (( NO_BUMP )); then
    VERSION="$CURRENT_VERSION"
elif [[ -z "$VERSION" ]]; then
    VERSION="$(increment_version "$CURRENT_VERSION" "$MODE")"
fi
if [[ "$VERSION" != <->.<->.<-> ]]; then
    print -u2 "版本号必须是 major.minor.patch：$VERSION"
    exit 2
fi

CURRENT_BUILD="$(read_plist CFBundleVersion)"
if [[ "$CURRENT_BUILD" != <-> ]]; then
    print -u2 "构建号必须是整数：$CURRENT_BUILD"
    exit 2
fi
if (( NO_BUMP )); then
    NEXT_BUILD="$CURRENT_BUILD"
else
    NEXT_BUILD=$(( CURRENT_BUILD + 1 ))
    write_plist CFBundleShortVersionString "$VERSION"
    write_plist CFBundleVersion "$NEXT_BUILD"
fi

print "版本已更新：$CURRENT_VERSION ($CURRENT_BUILD) -> $VERSION ($NEXT_BUILD)"
"$BUILD_SCRIPT" all

for arch in intel arm64; do
    app="$DIST_DIR/模型状态-$arch.app"
    zip="$DIST_DIR/模型状态-$VERSION-$arch.zip"
    rm -f "$zip"
    ditto -c -k --keepParent "$app" "$zip"
    shasum -a 256 "$zip"
done
print "打包完成：$DIST_DIR/模型状态-$VERSION-intel.zip"
print "打包完成：$DIST_DIR/模型状态-$VERSION-arm64.zip"
