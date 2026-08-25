#!/bin/zsh

set -euo pipefail

script_dir=${0:A:h}

if [[ $# -ne 1 ]]; then
    print -u2 "用法：$0 '/绝对路径/DSD Pancake.dmg'"
    exit 64
fi

dmg_path=${1:A}
temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/dsd-pancake-dmg-verify.XXXXXX")"
mount_point="$temporary_dir/mount"
mounted=false

cleanup() {
    if [[ "$mounted" == true ]]; then
        if /usr/bin/hdiutil detach -quiet "$mount_point"; then
            mounted=false
        else
            print -u2 "警告：无法卸载验证用 DMG，请手工执行：hdiutil detach '$mount_point'"
            return
        fi
    fi
    /bin/rm -rf -- "$temporary_dir"
}
trap cleanup EXIT

for required_path in \
    "$script_dir/verify-app.zsh" \
    /bin/mkdir \
    /usr/bin/find \
    /usr/bin/hdiutil \
    /usr/bin/readlink \
    /usr/bin/shasum; do
    if [[ ! -x "$required_path" && ! -f "$required_path" ]]; then
        print -u2 "缺少 DMG 验证所需文件或工具：$required_path"
        exit 1
    fi
done

if [[ ! -f "$dmg_path" ]]; then
    print -u2 "未找到 DMG（磁盘映像）：$dmg_path"
    exit 1
fi

/usr/bin/hdiutil verify -quiet "$dmg_path"
/bin/mkdir -p "$mount_point"
/usr/bin/hdiutil attach \
    -quiet \
    -readonly \
    -nobrowse \
    -noautoopen \
    -mountpoint "$mount_point" \
    "$dmg_path"
mounted=true

mounted_app="$mount_point/DSD Pancake.app"
applications_link="$mount_point/Applications"

if [[ ! -d "$mounted_app" ]]; then
    print -u2 "DMG 中缺少 DSD Pancake.app"
    exit 1
fi

if [[ ! -L "$applications_link" ]]; then
    print -u2 "DMG 中缺少 Applications 快捷入口"
    exit 1
fi

applications_target=$(/usr/bin/readlink "$applications_link")
if [[ "$applications_target" != "/Applications" ]]; then
    print -u2 "Applications 快捷入口目标不正确：$applications_target"
    exit 1
fi

unexpected_root_entry=$(/usr/bin/find "$mount_point" -mindepth 1 -maxdepth 1 \
    ! -name 'DSD Pancake.app' \
    ! -name 'Applications' \
    -print -quit)
if [[ -n "$unexpected_root_entry" ]]; then
    print -u2 "DMG 根目录包含非预期内容：$unexpected_root_entry"
    exit 1
fi

# 在只读挂载后的真实磁盘映像中再次检查 App，避免只验证 staging（暂存目录）。
/bin/zsh "$script_dir/verify-app.zsh" "$mounted_app"

/usr/bin/hdiutil detach -quiet "$mount_point"
mounted=false
dmg_sha256=$(/usr/bin/shasum -a 256 "$dmg_path" | /usr/bin/awk '{print $1}')

print "PASS: DMG 校验和、只读挂载、App 签名与 Applications 快捷入口均有效"
print "PASS: DMG SHA-256 = $dmg_sha256"
