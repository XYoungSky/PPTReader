#!/bin/zsh
# 固定的自签名代码签名证书。用它签名后，应用的身份只和证书有关，不随每次构建变化，
# 所以升级后钥匙串的“始终允许”和麦克风等授权都还有效。证书没有经过 Apple 公证，
# 第一次打开时 macOS 照样会拦截，这一点和临时签名（ad-hoc）一样。
#
# 用法：
#   ./scripts/signing.sh create          # 生成证书（每台打包用的 Mac 只需一次）
#   ./scripts/signing.sh status          # 查看证书
#   ./scripts/signing.sh export <文件>   # 导出备份（.p12，会要求设置密码），换电脑打包时用
#   ./scripts/signing.sh import <文件>   # 在另一台 Mac 上导入备份
#   ./scripts/signing.sh unlock          # 给 build-app.sh 用：解锁并输出证书的 SHA-1
#
# 证书放在单独的钥匙串 ~/Library/Keychains/PPTReader-Signing.keychain-db 里（不在项目目录，
# 不随 iCloud 同步）。这个钥匙串的密码是随机生成的，存在登录钥匙串里，打包时自动取出解锁。
# 丢了证书再生成一张新的，用户升级时会再被问一次钥匙串，之后又不再问。
set -euo pipefail

NAME="PPTReader Signing"
KEYCHAIN="$HOME/Library/Keychains/PPTReader-Signing.keychain-db"
PW_SERVICE="PPTReader Signing Keychain"
PW_ACCOUNT="build"

password() {
  security find-generic-password -s "$PW_SERVICE" -a "$PW_ACCOUNT" -w 2>/dev/null
}

identity() {
  security find-certificate -c "$NAME" -Z "$KEYCHAIN" 2>/dev/null | awk '/SHA-1/ { print $3; exit }'
}

unlock() {
  [[ -f "$KEYCHAIN" ]] || return 1
  local pw; pw=$(password) || return 1
  security unlock-keychain -p "$pw" "$KEYCHAIN"
  local sha; sha=$(identity)
  [[ -n "$sha" ]] || return 1
  echo "$sha"
}

# 新建空的签名钥匙串，随机密码存进登录钥匙串。
new_keychain() {
  if [[ -f "$KEYCHAIN" ]]; then
    echo "已经有 $KEYCHAIN。要重新生成，先删掉它：security delete-keychain \"$KEYCHAIN\"" >&2
    exit 1
  fi
  local pw; pw=$(openssl rand -hex 24)
  # 只有最后一行（密码）输出到 stdout，调用方用 $(…) 取。
  {
    security create-keychain -p "$pw" "$KEYCHAIN"
    security set-keychain-settings "$KEYCHAIN"   # 不自动锁定
    security add-generic-password -U -s "$PW_SERVICE" -a "$PW_ACCOUNT" -w "$pw" -T /usr/bin/security \
      -j "PPTReader 打包时用来解锁签名钥匙串" "$HOME/Library/Keychains/login.keychain-db"
    security unlock-keychain -p "$pw" "$KEYCHAIN"
  } >&2
  echo "$pw"
}

# 导入 .p12，并允许 codesign 直接使用私钥（不弹窗）。
import_p12() {
  local file="$1" p12pw="$2" pw="$3"
  security import "$file" -k "$KEYCHAIN" -P "$p12pw" -T /usr/bin/codesign >/dev/null
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$pw" "$KEYCHAIN" >/dev/null
}

case "${1:-}" in
  create)
    work=$(mktemp -d "${TMPDIR:-/tmp}/pptreader-cert.XXXXXX")
    trap 'rm -rf "$work"' EXIT
    cat > "$work/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
EOF
    # 有效期 30 年：证书过期后签不了名，换证书又会让用户再允许一次。
    openssl req -x509 -newkey rsa:3072 -nodes -keyout "$work/key.pem" -out "$work/cert.pem" \
      -days 10950 -config "$work/cert.cnf" 2>/dev/null
    p12pw=$(openssl rand -hex 16)
    openssl pkcs12 -export -inkey "$work/key.pem" -in "$work/cert.pem" -out "$work/id.p12" \
      -passout "pass:$p12pw" -name "$NAME"
    pw=$(new_keychain)
    import_p12 "$work/id.p12" "$p12pw" "$pw"
    echo "已生成证书 “$NAME”（SHA-1 $(identity)）"
    echo "   建议备份：./scripts/signing.sh export ~/Documents/PPTReader-Signing.p12"
    ;;
  import)
    file="${2:?用法：./scripts/signing.sh import <文件.p12>}"
    read -rs "p12pw?备份的密码：" && echo
    pw=$(new_keychain)
    import_p12 "$file" "$p12pw" "$pw"
    echo "已导入证书 “$NAME”（SHA-1 $(identity)）"
    ;;
  export)
    file="${2:?用法：./scripts/signing.sh export <文件.p12>}"
    unlock >/dev/null || { echo "没有找到证书，先运行 ./scripts/signing.sh create" >&2; exit 1; }
    [[ -t 0 ]] || { echo "要在“终端”App 里运行（需要输入密码）。" >&2; exit 1; }
    echo "给这份备份设一个新密码（自己定，以后在另一台 Mac 上导入时要用；输入时不显示）。"
    read -rs "p12pw?备份密码：" && echo
    read -rs "again?再输入一次：" && echo
    [[ -n "$p12pw" ]] || { echo "密码不能为空" >&2; exit 1; }
    [[ "$p12pw" == "$again" ]] || { echo "两次输入的密码不一样" >&2; exit 1; }
    # 导出私钥时 macOS 一定会弹窗，要求输入签名钥匙串的密码。这个密码是 create 时随机生成的，
    # 存在登录钥匙串里，这里复制到剪贴板，粘贴进弹窗即可。
    password | tr -d '\n' | pbcopy
    echo "接下来 macOS 会弹窗，要求输入“PPTReader-Signing”钥匙串的密码。"
    echo "这个密码已经复制到剪贴板，在弹窗里按 ⌘V 粘贴，再点“允许”。"
    if ! security export -k "$KEYCHAIN" -t identities -f pkcs12 -P "$p12pw" -o "$file"; then
      printf '' | pbcopy
      echo "导出失败（弹窗里点了拒绝，或者密码不对）。" >&2
      exit 1
    fi
    printf '' | pbcopy
    chmod 600 "$file"
    echo "已导出到 $file。私钥在里面，不要放进项目目录或公开的地方。"
    ;;
  status)
    if sha=$(unlock); then
      echo "证书 “$NAME”，SHA-1 $sha"
      security find-certificate -c "$NAME" -p "$KEYCHAIN" | openssl x509 -noout -enddate
    else
      echo "没有证书（./scripts/signing.sh create 生成），build-app.sh 会用临时签名。"
      exit 1
    fi
    ;;
  unlock)
    unlock
    ;;
  *)
    sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
    ;;
esac
