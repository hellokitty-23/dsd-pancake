#!/bin/zsh

set -euo pipefail

script_dir=${0:A:h}
project_root=${script_dir:h:h}
output_dir="${DSHD_OUTPUT_DIR:-$project_root/local-release}"
output_dir=${output_dir:A}
app_path="$output_dir/DSD Pancake.app"
archive_path="$output_dir/DSD Pancake.app.zip"
metadata_path="$output_dir/DSD Pancake.build.plist"
plist_path="$project_root/Resources/Info.plist"

for required_path in /usr/bin/grep /usr/libexec/PlistBuddy; do
    if [[ ! -x "$required_path" ]]; then
        print -u2 "缺少 Release 版本读取工具：$required_path"
        exit 1
    fi
done

if [[ ! -f "$plist_path" ]]; then
    print -u2 "缺少 Release 版本来源：$plist_path"
    exit 1
fi
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist_path")
if ! print -r -- "$version" | /usr/bin/grep -Eq '^[0-9A-Za-z][0-9A-Za-z._-]*$'; then
    print -u2 "App 版本号不能安全用于 Release 文件名：$version"
    exit 1
fi
dmg_path="$output_dir/DSD-Pancake-v${version}-arm64.dmg"
checksum_path="${dmg_path}.sha256"

for required_script in \
    "$script_dir/build-app.zsh" \
    "$script_dir/build-dmg.zsh" \
    "$script_dir/verify-dmg.zsh"; do
    if [[ ! -f "$required_script" ]]; then
        print -u2 "缺少 Release 打包脚本：$required_script"
        exit 1
    fi
done

for output_path in "$app_path" "$archive_path" "$metadata_path" "$dmg_path" "$checksum_path"; do
    if [[ -e "$output_path" || -L "$output_path" ]]; then
        print -u2 "拒绝覆盖既有本地产物：$output_path"
        print -u2 "请先人工确认并移走旧产物，或设置 DSHD_OUTPUT_DIR 指向空目录。"
        exit 2
    fi
done

DSHD_OUTPUT_DIR="$output_dir" /bin/zsh "$script_dir/build-app.zsh"
/bin/zsh "$script_dir/build-dmg.zsh" "$app_path" "$dmg_path"
/bin/zsh "$script_dir/verify-dmg.zsh" "$dmg_path"

print "本机 Release 打包完成：$output_dir"
print "推荐发布给用户的文件：$dmg_path"
print "请与 DMG 一起发布校验文件：$checksum_path"
