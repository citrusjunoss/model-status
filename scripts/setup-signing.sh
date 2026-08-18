#!/bin/zsh
set -euo pipefail

IDENTITY_NAME="${MODEL_STATUS_SIGN_IDENTITY:-ModelStatus Local Signing}"
DEFAULT_KEYCHAIN="$(security default-keychain -d user | sed -E 's/^[[:space:]]*\"//; s/\"[[:space:]]*$//')"
KEYCHAIN_PATH="${MODEL_STATUS_SIGNING_KEYCHAIN:-$DEFAULT_KEYCHAIN}"
OPENSSL_BIN="$(command -v openssl)"

if security find-identity -v -p codesigning "$KEYCHAIN_PATH" | /usr/bin/grep -F "\"$IDENTITY_NAME\"" >/dev/null; then
    echo "签名证书已存在：$IDENTITY_NAME"
    exit 0
fi

if ! "$OPENSSL_BIN" req -help 2>&1 | /usr/bin/grep -q -- "-addext"; then
    print -u2 "当前 OpenSSL 不支持 -addext，无法创建代码签名证书。"
    exit 2
fi

TASK_TEMP_DIR="$(mktemp -d /private/tmp/model-status-signing.XXXXXX)"
trap 'rm -rf "$TASK_TEMP_DIR"' EXIT

PRIVATE_KEY="$TASK_TEMP_DIR/private-key.pem"
CERTIFICATE="$TASK_TEMP_DIR/certificate.pem"
IDENTITY_ARCHIVE="$TASK_TEMP_DIR/identity.p12"
ARCHIVE_PASSWORD="$($OPENSSL_BIN rand -hex 24)"

"$OPENSSL_BIN" req \
    -new \
    -newkey rsa:2048 \
    -x509 \
    -sha256 \
    -days 3650 \
    -nodes \
    -subj "/CN=$IDENTITY_NAME/O=ModelStatus" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" \
    -keyout "$PRIVATE_KEY" \
    -out "$CERTIFICATE"

"$OPENSSL_BIN" pkcs12 \
    -export \
    -legacy \
    -name "$IDENTITY_NAME" \
    -inkey "$PRIVATE_KEY" \
    -in "$CERTIFICATE" \
    -out "$IDENTITY_ARCHIVE" \
    -passout "pass:$ARCHIVE_PASSWORD"

security import "$IDENTITY_ARCHIVE" \
    -k "$KEYCHAIN_PATH" \
    -P "$ARCHIVE_PASSWORD" \
    -T /usr/bin/codesign \
    -T /usr/bin/security

security add-trusted-cert \
    -d \
    -r trustRoot \
    -p codeSign \
    -k "$KEYCHAIN_PATH" \
    "$CERTIFICATE"

if ! security find-identity -v -p codesigning "$KEYCHAIN_PATH" | /usr/bin/grep -F "\"$IDENTITY_NAME\"" >/dev/null; then
    print -u2 "证书已导入，但未成为有效的代码签名身份。"
    exit 3
fi

echo "已创建稳定签名证书：$IDENTITY_NAME"
