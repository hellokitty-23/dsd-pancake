#!/bin/zsh

set -euo pipefail

script_dir=${0:A:h}

if [[ $# -lt 1 || $# -gt 2 ]]; then
    print -u2 "用法：$0 '/绝对路径/DSD Pancake.app' ['/绝对路径/DSD-Pancake-v版本-arm64.dmg']"
    exit 64
fi

app_path=${1:A}
plist_path="$app_path/Contents/Info.plist"
temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/dsd-pancake-dmg.XXXXXX")"
staging_dir="$temporary_dir/staging"
temporary_image="$temporary_dir/DSD Pancake.dmg"
temporary_checksum="$temporary_dir/DSD Pancake.dmg.sha256"

cleanup() {
    /bin/rm -rf -- "$temporary_dir"
}
trap cleanup EXIT

for required_path in \
    "$script_dir/verify-app.zsh" \
    /bin/ln \
    /bin/mkdir \
    /bin/mv \
    /usr/bin/ditto \
    /usr/bin/grep \
    /usr/bin/hdiutil \
    /usr/bin/awk \
    /usr/bin/printf \
    /usr/bin/shasum \
    /usr/libexec/PlistBuddy; do
    if [[ ! -x "$required_path" && ! -f "$required_path" ]]; then
        print -u2 "缺少 DMG 打包所需文件或工具：$required_path"
        exit 1
    fi
done

if [[ ! -d "$app_path" || ! -f "$plist_path" ]]; then
    print -u2 "未找到可打包的 App bundle（应用包）：$app_path"
    exit 1
fi

version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist_path")
if ! print -r -- "$version" | /usr/bin/grep -Eq '^[0-9A-Za-z][0-9A-Za-z._-]*$'; then
    print -u2 "App 版本号不能安全用于 DMG 卷标或发布文件名：$version"
    exit 1
fi

expected_dmg_name="DSD-Pancake-v${version}-arm64.dmg"
if [[ $# -eq 2 ]]; then
    dmg_path=${2:a}
else
    dmg_path="${app_path:h}/$expected_dmg_name"
fi
checksum_path="${dmg_path}.sha256"

if [[ "$dmg_path" == "$app_path"/* ]]; then
    print -u2 "DMG 输出不能位于已签名的 App bundle 内：$dmg_path"
    exit 1
fi

if [[ "${dmg_path:t}" != "$expected_dmg_name" ]]; then
    print -u2 "DMG 发布文件名必须是 $expected_dmg_name：$dmg_path"
    exit 1
fi

if [[ -e "$dmg_path" || -L "$dmg_path" || -e "$checksum_path" || -L "$checksum_path" ]]; then
    print -u2 "拒绝覆盖既有 DMG 或 SHA-256 校验文件：$dmg_path"
    exit 2
fi

# 只把已经通过现有严格白名单与签名检查的 App 放进磁盘映像。
/bin/zsh "$script_dir/verify-app.zsh" "$app_path"

/bin/mkdir -p "$staging_dir"
# Apple 建议使用 ditto 而不是 cp，以保留 App bundle 与符号链接语义。
/usr/bin/ditto "$app_path" "$staging_dir/DSD Pancake.app"
/bin/ln -s /Applications "$staging_dir/Applications"

/usr/bin/hdiutil create \
    -quiet \
    -srcfolder "$staging_dir" \
    -volname "DSD Pancake $version" \
    -fs HFS+ \
    -format UDZO \
    -imagekey zlib-level=9 \
    "$temporary_image"
/usr/bin/hdiutil verify -quiet "$temporary_image"

/bin/mkdir -p "${dmg_path:h}"
dmg_sha256=$(/usr/bin/shasum -a 256 "$temporary_image" | /usr/bin/awk '{print $1}')
/usr/bin/printf '%s  %s\n' "$dmg_sha256" "${dmg_path:t}" > "$temporary_checksum"
/bin/mv "$temporary_image" "$dmg_path"
/bin/mv "$temporary_checksum" "$checksum_path"

print "已生成拖拽安装 DMG：$dmg_path"
print "已生成 SHA-256 校验文件：$checksum_path"
print "卷内包含 DSD Pancake.app 与 Applications 快捷入口。"
print "DMG SHA-256：$dmg_sha256"
