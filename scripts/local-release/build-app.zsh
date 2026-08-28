#!/bin/zsh

set -euo pipefail

script_dir=${0:A:h}
project_root=${script_dir:h:h}
resources_dir="$project_root/Resources"
plugin_catalog="$project_root/scripts/private-plugin-catalog.mjs"
plugin_catalog_json="$project_root/scripts/private-plugins.json"
plugin_metadata_verifier="$project_root/scripts/verify-private-plugin-metadata.mjs"
output_dir="${DSHD_OUTPUT_DIR:-$project_root/local-release}"
output_dir=${output_dir:A}
test_mode="${DSHD_TEST_MODE:-0}"
app_display_name="DSD Pancake"
bundle_identifier="io.github.hellokitty-23.dsd-pancake"
production_bundle_identifier="io.github.hellokitty-23.dsd-pancake"
service_port="3080"
test_dsh_home=""
test_downloads_directory=""
test_app_version="${DSHD_TEST_APP_VERSION:-}"

if [[ "$test_mode" != "0" && "$test_mode" != "1" ]]; then
    print -u2 "DSHD_TEST_MODE 只能是 0 或 1。"
    exit 64
fi
if [[ "$test_mode" == "0" && -n "$test_app_version" ]]; then
    print -u2 "DSHD_TEST_APP_VERSION 只能用于隔离 Test App。"
    exit 64
fi
if [[ "$test_mode" == "1" ]]; then
    app_display_name="${DSHD_APP_DISPLAY_NAME:-DSD Pancake Test}"
    bundle_identifier="${DSHD_BUNDLE_IDENTIFIER:-io.github.hellokitty-23.dsd-pancake.test}"
    service_port="${DSHD_SERVICE_PORT:-13080}"
    test_dsh_home="${DSHD_TEST_DSH_HOME:-$output_dir/test-dsh-home}"
    test_downloads_directory="${DSHD_TEST_DOWNLOADS_DIR:-$output_dir/test-downloads}"
    test_dsh_home=${test_dsh_home:A}
    test_downloads_directory=${test_downloads_directory:A}
    formal_app_support="$HOME/Library/Application Support/$production_bundle_identifier"
    formal_app_support=${formal_app_support:A}
    canonical_home=${HOME:A}
    output_dir_lower=${output_dir:l}
    canonical_home_lower=${canonical_home:l}

    if [[ "${bundle_identifier:l}" == "${production_bundle_identifier:l}" ]]; then
        print -u2 "隔离 Test App 必须使用不同于正式 App 的 bundle ID。"
        exit 64
    fi
    if [[ "$output_dir_lower" == "/" || "$output_dir_lower" == "$canonical_home_lower" ]]; then
        print -u2 "隔离 Test 输出目录不能是文件系统根目录或用户主目录：$output_dir"
        exit 64
    fi
    for protected_root in "$HOME/.dsh" "$HOME/Downloads" "$formal_app_support"; do
        protected_root=${protected_root:A}
        protected_root_lower=${protected_root:l}
        if [[ "$output_dir_lower" == "$protected_root_lower" \
              || "$output_dir_lower" == "$protected_root_lower"/* ]]; then
            print -u2 "隔离 Test 输出目录不能位于正式数据目录内：$output_dir"
            exit 64
        fi
    done
    if [[ "$service_port" != <-> || "$service_port" -lt 1024 || "$service_port" -gt 65535 || "$service_port" -eq 3080 ]]; then
        print -u2 "隔离 Test App 端口必须是 1024...65535 内且不能为 3080：$service_port"
        exit 64
    fi
    if [[ "${test_dsh_home:l}" != "$output_dir_lower"/* ]]; then
        print -u2 "隔离 Test App 的 DSH_HOME 必须位于本次 Test 输出目录内。"
        exit 64
    fi
    if [[ "${test_downloads_directory:l}" != "$output_dir_lower"/* ]]; then
        print -u2 "隔离 Test App 的下载目录必须位于本次 Test 输出目录内。"
        exit 64
    fi
    if ! print -r -- "$app_display_name" | /usr/bin/grep -Eq '^[A-Za-z0-9][A-Za-z0-9 _.-]*$'; then
        print -u2 "Test App 名称包含不安全字符：$app_display_name"
        exit 64
    fi
    if [[ -n "$test_app_version" ]] \
        && ! print -r -- "$test_app_version" \
            | /usr/bin/grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+([+-][0-9A-Za-z.-]+)?$'; then
        print -u2 "Test App 版本不是受支持的 SemVer：$test_app_version"
        exit 64
    fi
fi

final_app_path="$output_dir/$app_display_name.app"
final_archive_path="$output_dir/$app_display_name.app.zip"
final_metadata_path="$output_dir/$app_display_name.build.plist"

if [[ -e "$final_app_path" || -L "$final_app_path" \
      || -e "$final_archive_path" || -L "$final_archive_path" \
      || -e "$final_metadata_path" || -L "$final_metadata_path" ]]; then
    print -u2 "拒绝覆盖既有本地产物：$output_dir"
    print -u2 "请先人工确认并移走旧产物，或设置 DSHD_OUTPUT_DIR 指向空目录。"
    exit 2
fi

# staging 与最终产物位于同一文件系统，发布时只需 rename，不会退化为跨卷复制。
# 三件套全部构建、验证和签名成功前，output_dir 中不会出现最终名称。
mkdir -p "$output_dir"
temporary_dir="$(/usr/bin/mktemp -d "$output_dir/.dshdesktop-build.XXXXXX")"
app_path="$temporary_dir/$app_display_name.app"
archive_path="$temporary_dir/$app_display_name.app.zip"
metadata_path="$temporary_dir/$app_display_name.build.plist"
published_paths=()
published_identities=()
publication_committed=0
cleanup_started=0

artifact_identity() {
    /usr/bin/stat -f '%d:%i' "$1"
}

rollback_published_artifacts() {
    local index published_path expected_identity current_identity
    for (( index = ${#published_paths[@]}; index >= 1; index -= 1 )); do
        published_path="${published_paths[$index]}"
        expected_identity="${published_identities[$index]}"
        if [[ ! -e "$published_path" && ! -L "$published_path" ]]; then
            continue
        fi
        if ! current_identity=$(artifact_identity "$published_path" 2>/dev/null); then
            print -u2 "无法确认本次发布产物的身份，保留现场供人工检查：$published_path"
            continue
        fi
        if [[ "$current_identity" != "$expected_identity" ]]; then
            print -u2 "发布目标已被其它进程替换，不删除非本次产物：$published_path"
            continue
        fi
        if [[ -d "$published_path" && ! -L "$published_path" ]]; then
            /bin/rm -rf -- "$published_path" \
                || print -u2 "无法回滚本次发布目录，请人工检查：$published_path"
        else
            /bin/rm -f -- "$published_path" \
                || print -u2 "无法回滚本次发布文件，请人工检查：$published_path"
        fi
    done
}

cleanup() {
    local exit_status=$?
    if (( $# > 0 )); then
        exit_status="$1"
    fi
    if (( cleanup_started != 0 )); then
        return "$exit_status"
    fi
    cleanup_started=1
    trap - EXIT ZERR
    if (( exit_status != 0 && publication_committed == 0 )); then
        rollback_published_artifacts
    fi
    /bin/rm -rf -- "$temporary_dir" \
        || print -u2 "无法清理本次 staging 目录，请人工检查：$temporary_dir"
    return "$exit_status"
}
trap cleanup EXIT

# zsh 的 ERR_EXIT（`set -e`）在函数返回失败时不会可靠执行 EXIT trap。
# ZERR 先执行同一清理路径，确保 build_icns、metadata 或发布函数失败也能回滚。
TRAPZERR() {
    local exit_status=$?
    cleanup "$exit_status"
    return "$exit_status"
}

publish_without_overwrite() {
    local source_path="$1"
    local destination_path="$2"
    local source_identity destination_identity
    local move_status=0

    if [[ -e "$destination_path" || -L "$destination_path" ]]; then
        print -u2 "发布期间目标已出现，拒绝覆盖：$destination_path"
        return 2
    fi
    source_identity=$(artifact_identity "$source_path")
    # 目标参数使用父目录而不是可能在竞态中出现的同名目录；否则 mv 会把
    # source 嵌进该目录，而不是按同名目标执行 no-clobber（不覆盖）。
    /bin/mv -n "$source_path" "${destination_path:h}" || move_status=$?

    # macOS mv -n 在目标已存在时可能保持成功退出，因此必须检查 source 是否仍在。
    if [[ -e "$source_path" || -L "$source_path" ]]; then
        print -u2 "未发布 staging 产物，目标可能已被其它进程占用：$destination_path"
        return 2
    fi
    if [[ ! -e "$destination_path" && ! -L "$destination_path" ]]; then
        print -u2 "staging 产物已离开但发布目标不存在：$destination_path"
        return 1
    fi
    destination_identity=$(artifact_identity "$destination_path")
    if [[ "$destination_identity" != "$source_identity" ]]; then
        print -u2 "发布目标身份与本次 staging 产物不一致，不删除该目标：$destination_path"
        return 1
    fi

    published_paths+=("$destination_path")
    published_identities+=("$destination_identity")
    if (( move_status != 0 )); then
        print -u2 "rename 返回失败，回滚本次已发布产物：$destination_path"
        return "$move_status"
    fi
}

node_path=${commands[node]:-}
if [[ -z "$node_path" || ! -x "$node_path" ]]; then
    print -u2 "缺少私有插件清单校验所需的 Node.js。"
    exit 1
fi
for catalog_path in "$plugin_catalog_json" "$plugin_catalog" "$plugin_metadata_verifier"; do
    if [[ ! -f "$catalog_path" || -L "$catalog_path" ]]; then
        print -u2 "缺少私有插件清单文件，或路径是符号链接：$catalog_path"
        exit 1
    fi
done

plugin_rows=("${(@f)$("$node_path" "$plugin_catalog" rows)}")
plugin_required_files=("${(@f)$("$node_path" "$plugin_catalog" required-files)}")
plugin_verifiers=("${(@f)$("$node_path" "$plugin_catalog" verifiers)}")
plugin_source_files=()
plugin_verifier_files=()
for plugin_row in "${plugin_rows[@]}"; do
    IFS=$'\t' read -r source_directory resource_directory package_name patch_id plugin_label <<< "$plugin_row"
    for relative_file in "${plugin_required_files[@]}"; do
        plugin_source_files+=("$project_root/$source_directory/$relative_file")
    done
done
for relative_verifier in "${plugin_verifiers[@]}"; do
    plugin_verifier_files+=("$project_root/$relative_verifier")
done

for required_path in \
    "$resources_dir/Info.plist" \
    "$resources_dir/AppIcon.png" \
    "$resources_dir/DockIcon.png" \
    "${plugin_source_files[@]}" \
    "${plugin_verifier_files[@]}"; do
    if [[ ! -f "$required_path" || -L "$required_path" ]]; then
        print -u2 "缺少本机打包所需普通文件，或路径是符号链接：$required_path"
        exit 1
    fi
done

"$node_path" "$plugin_metadata_verifier" --source-root "$project_root"
"$node_path" "$plugin_metadata_verifier" --self-test
for verifier_path in "${plugin_verifier_files[@]}"; do
    "$node_path" "$verifier_path"
done

for required_tool in \
    /bin/mv \
    /usr/bin/git \
    /usr/bin/swift \
    /usr/bin/sips \
    /usr/bin/iconutil \
    /usr/bin/ditto \
    /usr/bin/cmp \
    /usr/bin/codesign \
    /usr/bin/plutil \
    /usr/bin/stat \
    /usr/libexec/PlistBuddy; do
    if [[ ! -f "$required_tool" || ! -x "$required_tool" ]]; then
        print -u2 "缺少本机打包所需可执行工具：$required_tool"
        exit 1
    fi
done

/usr/bin/swift build \
    -c release \
    --product DSHDesktop \
    --package-path "$project_root" \
    --scratch-path "$temporary_dir/swift-build"
bin_path=$(/usr/bin/swift build \
    -c release \
    --show-bin-path \
    --package-path "$project_root" \
    --scratch-path "$temporary_dir/swift-build")
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

mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
for plugin_row in "${plugin_rows[@]}"; do
    IFS=$'\t' read -r source_directory resource_directory package_name patch_id plugin_label <<< "$plugin_row"
    mkdir -p "$app_path/Contents/Resources/$resource_directory/lib"
done
/usr/bin/ditto "$executable_path" "$app_path/Contents/MacOS/DSHDesktop"
/usr/bin/ditto "$resources_dir/Info.plist" "$app_path/Contents/Info.plist"
if [[ "$test_mode" == "1" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $app_display_name" "$app_path/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleName $app_display_name" "$app_path/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $bundle_identifier" "$app_path/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :DSDPancakeTestMode bool true" "$app_path/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :DSDPancakeTestRoot string $output_dir" "$app_path/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :DSDPancakeServicePort integer $service_port" "$app_path/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :DSDPancakeDSHHome string $test_dsh_home" "$app_path/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :DSDPancakeDownloadsDirectory string $test_downloads_directory" "$app_path/Contents/Info.plist"
    if [[ -n "$test_app_version" ]]; then
        /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $test_app_version" "$app_path/Contents/Info.plist"
    fi
fi
for plugin_row in "${plugin_rows[@]}"; do
    IFS=$'\t' read -r source_directory resource_directory package_name patch_id plugin_label <<< "$plugin_row"
    for relative_file in "${plugin_required_files[@]}"; do
        /usr/bin/ditto \
            "$project_root/$source_directory/$relative_file" \
            "$app_path/Contents/Resources/$resource_directory/$relative_file"
    done
done
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

# 下列门禁位于组装完成与签名之间，验证的就是即将进入签名 seal（签名封装）的
# bundle 字节。行为 verifier 先复核 source；随后 metadata verifier 在受限 sandbox
# 中直接读取 staging bundle，并用 cmp 保证每个发行插件文件与刚通过行为验证的
# source 逐字节一致。此后签名前不再修改任何插件文件。
for verifier_path in "${plugin_verifier_files[@]}"; do
    "$node_path" "$verifier_path"
done
"$node_path" "$plugin_metadata_verifier" --bundle-resources "$app_path/Contents/Resources"
for plugin_row in "${plugin_rows[@]}"; do
    IFS=$'\t' read -r source_directory resource_directory package_name patch_id plugin_label <<< "$plugin_row"
    for relative_file in "${plugin_required_files[@]}"; do
        source_file="$project_root/$source_directory/$relative_file"
        staged_file="$app_path/Contents/Resources/$resource_directory/$relative_file"
        if ! /usr/bin/cmp -s -- "$source_file" "$staged_file"; then
            print -u2 "$plugin_label 的 staging bundle 字节与已验证 source 不一致：$relative_file"
            exit 1
        fi
    done
done
print "PASS: staging bundle 的私有插件 metadata、行为与 source 字节一致，允许进入签名"

# 不使用开发者证书、Apple 账号或公证；`-` 是本机 ad-hoc（无身份）签名。
# 它在组装完成后把主程序、Info.plist 与资源绑定为同一个 App 身份，使
# UserNotifications 能稳定登记 `CFBundleIdentifier`。这不是对外分发签名。
/usr/bin/codesign --force --sign - "$app_path"
/usr/bin/codesign --verify --deep --strict --verbose=4 "$app_path"

/usr/bin/ditto -c -k --keepParent "$app_path" "$archive_path"

actual_bundle_identifier=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_path/Contents/Info.plist")
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_path/Contents/Info.plist")
build_number=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app_path/Contents/Info.plist")
git_revision="uncommitted"
if GIT_OPTIONAL_LOCKS=0 /usr/bin/git -C "$project_root" rev-parse --verify HEAD >/dev/null 2>&1; then
    git_revision=$(GIT_OPTIONAL_LOCKS=0 /usr/bin/git -C "$project_root" rev-parse --short=12 HEAD)
    if [[ -n "$(GIT_OPTIONAL_LOCKS=0 /usr/bin/git -C "$project_root" status --porcelain --untracked-files=normal)" ]]; then
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
/usr/libexec/PlistBuddy -c "Add :BundleIdentifier string $actual_bundle_identifier" "$metadata_path"
/usr/libexec/PlistBuddy -c "Add :Version string $version" "$metadata_path"
/usr/libexec/PlistBuddy -c "Add :BuildNumber string $build_number" "$metadata_path"
/usr/libexec/PlistBuddy -c "Add :GitRevision string $git_revision" "$metadata_path"
/usr/libexec/PlistBuddy -c "Add :Architecture string $architecture" "$metadata_path"
/usr/libexec/PlistBuddy -c "Add :ArchiveSHA256 string $archive_sha256" "$metadata_path"
/usr/libexec/PlistBuddy -c "Add :ExecutableSHA256 string $executable_sha256" "$metadata_path"
/usr/libexec/PlistBuddy -c "Add :Signed bool true" "$metadata_path"
/usr/libexec/PlistBuddy -c "Add :SigningMode string adhoc" "$metadata_path"
/usr/libexec/PlistBuddy -c "Add :IsolatedTestBuild bool $([[ \"$test_mode\" == \"1\" ]] && print true || print false)" "$metadata_path"
/usr/bin/plutil -lint "$metadata_path"

# build plist 最后发布，可作为三件套已经完整提交的完成标记。任一步 rename
# 失败都会进入统一清理路径，且只回滚本次已经成功发布、身份仍未变化的目标。
publish_without_overwrite "$app_path" "$final_app_path"
publish_without_overwrite "$archive_path" "$final_archive_path"
publish_without_overwrite "$metadata_path" "$final_metadata_path"
publication_committed=1

print "已生成本机 App：$final_app_path"
print "已完成本机 ad-hoc 签名（无需开发者证书或公证）。"
print "归档 SHA-256：$archive_sha256"
print "构建映射：$final_metadata_path"
