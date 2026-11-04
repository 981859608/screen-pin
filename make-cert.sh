#!/bin/zsh
# 生成一张只在本机使用的自签代码签名证书并导入登录钥匙串。
# 有了固定签名身份，ScreenCaptureKit 的录屏授权会绑定证书而不是可执行文件哈希，
# 之后重新构建不用再重新授权。私钥只进钥匙串，不在项目目录留文件。
set -e
CERT_NAME="${1:-ScreenPin Local}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "\"$CERT_NAME\""; then
  echo "已存在签名身份: $CERT_NAME，跳过生成"
  exit 0
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

cat > "$work/codesign.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = cs
prompt = no
[dn]
CN = $CERT_NAME
[cs]
basicConstraints = critical, CA:true
keyUsage = critical, digitalSignature, keyCertSign
extendedKeyUsage = codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "$work/key.pem" -out "$work/cert.pem" -days 3650 \
  -config "$work/codesign.cnf" -extensions cs
# security import 对空密码的 p12 会当成"需要口令"卡在交互输入上，所以用一个一次性口令。
pw=$(openssl rand -hex 12)
openssl pkcs12 -export -inkey "$work/key.pem" -in "$work/cert.pem" \
  -out "$work/identity.p12" -passout "pass:$pw"

security import "$work/identity.p12" -k "$KEYCHAIN" -P "$pw" -A -f pkcs12
echo "已导入签名身份: $CERT_NAME"
security find-identity -v -p codesigning "$KEYCHAIN"
