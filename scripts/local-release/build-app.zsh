#!/bin/zsh

set -euo pipefail

script_dir=${0:A:h}
project_root=${script_dir:h:h}
resources_dir="$project_root/Resources"
notification_plugin_dir="$project_root/Plugins/dsd-pancake-notifications"
terminal_plugin_dir="$project_root/Plugins/dsd-pancake-terminal"
output_dir="${DSHD_OUTPUT_DIR:-$project_root/local-release}"
app_path="$output_dir/DSD Pancake.app"
archive_path="$output_dir/DSD Pancake.app.zip"
metadata_path="$output_dir/DSD Pancake.build.plist"
temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/dshdesktop-build.XXXXXX")"

cleanup() {
    /bin/rm -rf -- "$temporary_dir"
}
trap cleanup EXIT

if [[ -e "$app_path" || -e "$archive_path" || -e "$metadata_path" ]]; then
    print -u2 "拒绝覆盖既有本地产物：$output_dir"
    print -u2 "请先人工确认并移走旧产物，或设置 DSHD_OUTPUT_DIR 指向空目录。"
    exit 2
fi

for required_path in \
    "$resources_dir/Info.plist" \
    "$resources_dir/AppIcon.png" \
    "$resources_dir/DockIcon.png" \
    "$notification_plugin_dir/package.json" \
    "$notification_plugin_dir/cordis.patch.yml" \
    "$notification_plugin_dir/lib/index.js" \
    "$notification_plugin_dir/lib/client.js" \
    "$terminal_plugin_dir/package.json" \
    "$terminal_plugin_dir/cordis.patch.yml" \
    "$terminal_plugin_dir/lib/index.js" \
    "$terminal_plugin_dir/lib/client.js" \
    /usr/bin/swift \
    /usr/bin/sips \
    /usr/bin/iconutil \
    /usr/bin/ditto \
    /usr/bin/codesign \
    /usr/bin/plutil \
    /usr/libexec/PlistBuddy; do
    if [[ ! -x "$required_path" && ! -f "$required_path" ]]; then
        print -u2 "缺少本机打包所需文件或工具：$required_path"
        exit 1
    fi
done

mkdir -p "$output_dir"
/usr/bin/swift build -c release --product DSHDesktop --package-path "$project_root"
bin_path=$(/usr/bin/swift build -c release --show-bin-path --package-path "$project_root")
executable_path="$bin_path/DSHDesktop"
swifterm_bundle_path="$bin_path/SwiftTerm_SwiftTerm.bundle"

if [[ ! -x "$executable_path" ]]; then
    print -u2 "未找到 Release 可执行文件：$executable_path"
    exit 1
fi

if [[ ! -d "$swifterm_bundle_path" || ! -f "$swifterm_bundle_path/Shaders.metal" ]]; then
    print -u2 "未找到 SwiftTerm 的已构建 Metal 资源：$swifterm_bundle_path"
    exit 1
fi

mkdir -p \
    "$app_path/Contents/MacOS" \
    "$app_path/Contents/Resources/DSHNotifications/lib" \
    "$app_path/Contents/Resources/DSHTerminal/lib" \
    "$app_path/Contents/Resources"
/usr/bin/ditto "$executable_path" "$app_path/Contents/MacOS/DSHDesktop"
/usr/bin/ditto "$resources_dir/Info.plist" "$app_path/Contents/Info.plist"
/usr/bin/ditto "$notification_plugin_dir/package.json" "$app_path/Contents/Resources/DSHNotifications/package.json"
/usr/bin/ditto "$notification_plugin_dir/cordis.patch.yml" "$app_path/Contents/Resources/DSHNotifications/cordis.patch.yml"
/usr/bin/ditto "$notification_plugin_dir/lib/index.js" "$app_path/Contents/Resources/DSHNotifications/lib/index.js"
/usr/bin/ditto "$notification_plugin_dir/lib/client.js" "$app_path/Contents/Resources/DSHNotifications/lib/client.js"
/usr/bin/ditto "$terminal_plugin_dir/package.json" "$app_path/Contents/Resources/DSHTerminal/package.json"
/usr/bin/ditto "$terminal_plugin_dir/cordis.patch.yml" "$app_path/Contents/Resources/DSHTerminal/cordis.patch.yml"
/usr/bin/ditto "$terminal_plugin_dir/lib/index.js" "$app_path/Contents/Resources/DSHTerminal/lib/index.js"
/usr/bin/ditto "$terminal_plugin_dir/lib/client.js" "$app_path/Contents/Resources/DSHTerminal/lib/client.js"
# SwiftTerm 1.20.0 的 Metal renderer 会从 `Bundle.main.resourceURL` 查找这个 bundle，
# 因此按 macOS 标准放进 Contents/Resources；不要把资源放在 .app 根目录，否则签名会
# 变成 unsealed contents（未封装内容）。
/usr/bin/ditto "$swifterm_bundle_path" "$app_path/Contents/Resources/SwiftTerm_SwiftTerm.bundle"

# `PancakeAppIcon` 是 bundle 主图标，供 Finder 和原生通知的 App 身份使用。
# 它刻意不复用历史的 `AppIcon` 资源键，以便 macOS 在替换本地 App 后重新解析
# 原生通知图标；源素材仍保持为 `Resources/AppIcon.png`。
# `DockIcon` 仅在运行时交给 AppKit 显示在 Dock；两套资源必须独立生成，
# 避免为小尺寸通知调整留白时意外缩小 Dock 的可见主体。
build_icns() {
    local source_path="$1"
    local icon_name="$2"
    local iconset_path="$temporary_dir/${icon_name}.iconset"
    local png_path="$temporary_dir/${icon_name}-1024.png"

    mkdir -p "$iconset_path"
    /usr/bin/sips -s format png "$source_path" --out "$png_path" >/dev/null
    /usr/bin/sips -z 16 16 "$png_path" --out "$iconset_path/icon_16x16.png" >/dev/null
    /usr/bin/sips -z 32 32 "$png_path" --out "$iconset_path/icon_16x16@2x.png" >/dev/null
    /usr/bin/sips -z 32 32 "$png_path" --out "$iconset_path/icon_32x32.png" >/dev/null
    /usr/bin/sips -z 64 64 "$png_path" --out "$iconset_path/icon_32x32@2x.png" >/dev/null
    /usr/bin/sips -z 128 128 "$png_path" --out "$iconset_path/icon_128x128.png" >/dev/null
    /usr/bin/sips -z 256 256 "$png_path" --out "$iconset_path/icon_128x128@2x.png" >/dev/null
    /usr/bin/sips -z 256 256 "$png_path" --out "$iconset_path/icon_256x256.png" >/dev/null
    /usr/bin/sips -z 512 512 "$png_path" --out "$iconset_path/icon_256x256@2x.png" >/dev/null
    /usr/bin/sips -z 512 512 "$png_path" --out "$iconset_path/icon_512x512.png" >/dev/null
    /usr/bin/sips -z 1024 1024 "$png_path" --out "$iconset_path/icon_512x512@2x.png" >/dev/null
    /usr/bin/iconutil -c icns "$iconset_path" -o "$app_path/Contents/Resources/${icon_name}.icns"
}

build_icns "$resources_dir/AppIcon.png" "PancakeAppIcon"
build_icns "$resources_dir/DockIcon.png" "DockIcon"

/usr/bin/plutil -lint "$app_path/Contents/Info.plist"
# 不使用开发者证书、Apple 账号或公证；`-` 是本机 ad-hoc（无身份）签名。
# 它在组装完成后把主程序、Info.plist 与资源绑定为同一个 App 身份，使
# UserNotifications 能稳定登记 `CFBundleIdentifier`。这不是对外分发签名。
/usr/bin/codesign --force --sign - "$app_path"
/usr/bin/codesign --verify --deep --strict --verbose=4 "$app_path"

/usr/bin/ditto -c -k --keepParent "$app_path" "$archive_path"

bundle_identifier=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_path/Contents/Info.plist")
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_path/Contents/Info.plist")
build_number=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app_path/Contents/Info.plist")
git_revision="uncommitted"
if git -C "$project_root" rev-parse --verify HEAD >/dev/null 2>&1; then
    git_revision=$(git -C "$project_root" rev-parse --short=12 HEAD)
    if [[ -n "$(git -C "$project_root" status --porcelain --untracked-files=normal)" ]]; then
        git_revision="${git_revision}-dirty"
    fi
fi
archive_sha256=$(/usr/bin/shasum -a 256 "$archive_path" | /usr/bin/awk '{print $1}')
executable_sha256=$(/usr/bin/shasum -a 256 "$app_path/Contents/MacOS/DSHDesktop" | /usr/bin/awk '{print $1}')
architecture=$(/usr/bin/lipo -archs "$app_path/Contents/MacOS/DSHDesktop")
app_name=${app_path:t}
archive_name=${archive_path:t}

/usr/bin/plutil -create xml1 "$metadata_path"
/usr/libexec/PlistBuddy -c "Add :AppPath string $app_name" "$metadata_path"
/usr/libexec/PlistBuddy -c "Add :ArchivePath string $archive_name" "$metadata_path"
/usr/libexec/PlistBuddy -c "Add :BundleIdentifier string $bundle_identifier" "$metadata_path"
/usr/libexec/PlistBuddy -c "Add :Version string $version" "$metadata_path"
/usr/libexec/PlistBuddy -c "Add :BuildNumber string $build_number" "$metadata_path"
/usr/libexec/PlistBuddy -c "Add :GitRevision string $git_revision" "$metadata_path"
/usr/libexec/PlistBuddy -c "Add :Architecture string $architecture" "$metadata_path"
/usr/libexec/PlistBuddy -c "Add :ArchiveSHA256 string $archive_sha256" "$metadata_path"
/usr/libexec/PlistBuddy -c "Add :ExecutableSHA256 string $executable_sha256" "$metadata_path"
/usr/libexec/PlistBuddy -c "Add :Signed bool true" "$metadata_path"
/usr/libexec/PlistBuddy -c "Add :SigningMode string adhoc" "$metadata_path"

print "已生成本机 Release App：$app_path"
print "已完成本机 ad-hoc 签名（无需开发者证书或公证）。"
print "归档 SHA-256：$archive_sha256"
print "构建映射：$metadata_path"
