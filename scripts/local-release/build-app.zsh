#!/bin/zsh

set -euo pipefail

script_dir=${0:A:h}
project_root=${script_dir:h:h}
resources_dir="$project_root/Resources"
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
    /usr/bin/swift \
    /usr/bin/sips \
    /usr/bin/iconutil \
    /usr/bin/ditto \
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

if [[ ! -x "$executable_path" ]]; then
    print -u2 "未找到 Release 可执行文件：$executable_path"
    exit 1
fi

mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
/usr/bin/ditto "$executable_path" "$app_path/Contents/MacOS/DSHDesktop"
/usr/bin/ditto "$resources_dir/Info.plist" "$app_path/Contents/Info.plist"

iconset_path="$temporary_dir/AppIcon.iconset"
png_path="$temporary_dir/AppIcon-1024.png"
mkdir -p "$iconset_path"
/usr/bin/sips -s format png "$resources_dir/AppIcon.png" --out "$png_path" >/dev/null
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
/usr/bin/iconutil -c icns "$iconset_path" -o "$app_path/Contents/Resources/AppIcon.icns"

/usr/bin/plutil -lint "$app_path/Contents/Info.plist"
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

/usr/bin/plutil -create xml1 "$metadata_path"
/usr/libexec/PlistBuddy -c "Add :AppPath string $app_path" "$metadata_path"
/usr/libexec/PlistBuddy -c "Add :ArchivePath string $archive_path" "$metadata_path"
/usr/libexec/PlistBuddy -c "Add :BundleIdentifier string $bundle_identifier" "$metadata_path"
/usr/libexec/PlistBuddy -c "Add :Version string $version" "$metadata_path"
/usr/libexec/PlistBuddy -c "Add :BuildNumber string $build_number" "$metadata_path"
/usr/libexec/PlistBuddy -c "Add :GitRevision string $git_revision" "$metadata_path"
/usr/libexec/PlistBuddy -c "Add :Architecture string $architecture" "$metadata_path"
/usr/libexec/PlistBuddy -c "Add :ArchiveSHA256 string $archive_sha256" "$metadata_path"
/usr/libexec/PlistBuddy -c "Add :ExecutableSHA256 string $executable_sha256" "$metadata_path"
/usr/libexec/PlistBuddy -c "Add :Signed bool false" "$metadata_path"

print "已生成本机 Release App：$app_path"
print "归档 SHA-256：$archive_sha256"
print "构建映射：$metadata_path"
