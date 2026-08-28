#!/bin/zsh

set -euo pipefail

script_dir=${0:A:h}
project_root=${script_dir:h:h}

if [[ $# -ne 1 ]]; then
    print -u2 "用法：$0 '/绝对路径/App.app'"
    exit 64
fi

app_path=${1:A}
plist_path="$app_path/Contents/Info.plist"
executable_path="$app_path/Contents/MacOS/DSHDesktop"
app_icon_path="$app_path/Contents/Resources/PancakeAppIcon.icns"
dock_icon_path="$app_path/Contents/Resources/DockIcon.icns"
signature_manifest_path="$app_path/Contents/_CodeSignature/CodeResources"
plugin_catalog="$project_root/scripts/private-plugin-catalog.mjs"
plugin_catalog_json="$project_root/scripts/private-plugins.json"
plugin_metadata_verifier="$project_root/scripts/verify-private-plugin-metadata.mjs"
swifterm_bundle_dir="$app_path/Contents/Resources/SwiftTerm_SwiftTerm.bundle"
swifterm_shader="$swifterm_bundle_dir/Shaders.metal"

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
plugin_bundle_files=()
plugin_bundle_directories=()
for plugin_row in "${plugin_rows[@]}"; do
    IFS=$'\t' read -r source_directory resource_directory package_name patch_id plugin_label <<< "$plugin_row"
    plugin_directory="$app_path/Contents/Resources/$resource_directory"
    plugin_bundle_directories+=("$plugin_directory" "$plugin_directory/lib")
    for relative_file in "${plugin_required_files[@]}"; do
        plugin_bundle_files+=("$plugin_directory/$relative_file")
    done
done

for required_path in \
    "$plist_path" \
    "$executable_path" \
    "$app_icon_path" \
    "$dock_icon_path" \
    "$signature_manifest_path" \
    "${plugin_bundle_files[@]}" \
    "$swifterm_shader"; do
    if [[ ! -f "$required_path" || -L "$required_path" ]]; then
        print -u2 "App 包缺少必需普通文件，或必需路径是符号链接：$required_path"
        exit 1
    fi
done

"$node_path" "$plugin_metadata_verifier" --bundle-resources "$app_path/Contents/Resources"

/usr/bin/plutil -lint "$plist_path"
/usr/bin/codesign --verify --deep --strict --verbose=4 "$app_path"
bundle_identifier=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist_path")
bundle_icon_name=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$plist_path")
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist_path")
build_number=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist_path")
automatic_termination=$(/usr/libexec/PlistBuddy -c 'Print :NSSupportsAutomaticTermination' "$plist_path")
sudden_termination=$(/usr/libexec/PlistBuddy -c 'Print :NSSupportsSuddenTermination' "$plist_path")
expected_bundle_identifier="${DSHD_EXPECTED_BUNDLE_IDENTIFIER:-io.github.hellokitty-23.dsd-pancake}"
expected_test_mode="${DSHD_EXPECTED_TEST_MODE:-0}"
expected_app_version="${DSHD_EXPECTED_APP_VERSION:-}"
test_mode=$(/usr/libexec/PlistBuddy -c 'Print :DSDPancakeTestMode' "$plist_path" 2>/dev/null || print false)

if [[ "$bundle_identifier" != "$expected_bundle_identifier" ]]; then
    print -u2 "bundle ID 不正确：$bundle_identifier"
    exit 1
fi

if [[ -n "$expected_app_version" && "$expected_test_mode" != "1" ]]; then
    print -u2 "版本覆盖校验只能用于隔离 Test App。"
    exit 64
fi
if [[ -n "$expected_app_version" && "$version" != "$expected_app_version" ]]; then
    print -u2 "Test App 版本覆盖未生效：期望 $expected_app_version，实际 $version"
    exit 1
fi

if [[ "$expected_test_mode" == "1" ]]; then
    display_name=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$plist_path")
    bundle_name=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleName' "$plist_path")
    service_port=$(/usr/libexec/PlistBuddy -c 'Print :DSDPancakeServicePort' "$plist_path")
    test_root=$(/usr/libexec/PlistBuddy -c 'Print :DSDPancakeTestRoot' "$plist_path")
    test_dsh_home=$(/usr/libexec/PlistBuddy -c 'Print :DSDPancakeDSHHome' "$plist_path")
    test_downloads_directory=$(/usr/libexec/PlistBuddy -c 'Print :DSDPancakeDownloadsDirectory' "$plist_path")
    test_root=${test_root:A}
    test_dsh_home=${test_dsh_home:A}
    test_downloads_directory=${test_downloads_directory:A}
    formal_app_support="$HOME/Library/Application Support/io.github.hellokitty-23.dsd-pancake"
    formal_app_support=${formal_app_support:A}
    test_root_lower=${test_root:l}
    test_dsh_home_lower=${test_dsh_home:l}
    test_downloads_directory_lower=${test_downloads_directory:l}
    canonical_home=${HOME:A}
    canonical_home_lower=${canonical_home:l}
    test_root_is_protected=false
    for protected_root in "$HOME/.dsh" "$HOME/Downloads" "$formal_app_support"; do
        protected_root=${protected_root:A}
        protected_root_lower=${protected_root:l}
        if [[ "$test_root_lower" == "$protected_root_lower" \
              || "$test_root_lower" == "$protected_root_lower"/* ]]; then
            test_root_is_protected=true
        fi
    done
    if [[ "$test_mode" != "true" \
          || "${bundle_identifier:l}" == "io.github.hellokitty-23.dsd-pancake" \
          || "$display_name" != "DSD Pancake Test" \
          || "$bundle_name" != "DSD Pancake Test" \
          || "$service_port" != <-> \
          || "$service_port" -lt 1024 \
          || "$service_port" -gt 65535 \
          || "$service_port" -eq 3080 \
          || "$test_root" != /* \
          || "$test_root_lower" == "/" \
          || "$test_root_lower" == "$canonical_home_lower" \
          || "$test_root_is_protected" == "true" \
          || "$test_dsh_home_lower" != "$test_root_lower"/* \
          || "$test_dsh_home_lower" == "/" \
          || "$test_dsh_home_lower" == "$canonical_home_lower" \
          || "$test_dsh_home_lower" == "${HOME:l}/.dsh" \
          || "$test_downloads_directory_lower" != "$test_root_lower"/* \
          || "$test_downloads_directory_lower" == "/" \
          || "$test_downloads_directory_lower" == "$canonical_home_lower" \
          || "$test_downloads_directory_lower" == "${HOME:l}/downloads" ]]; then
        print -u2 "隔离 Test App 的身份、端口、DSH_HOME 或下载目录配置不正确。"
        exit 1
    fi
else
    if [[ "$test_mode" != "false" ]]; then
        print -u2 "正式 App 中残留了 Test 构建标记。"
        exit 1
    fi
    if /usr/libexec/PlistBuddy -c 'Print :DSDPancakeServicePort' "$plist_path" >/dev/null 2>&1 \
        || /usr/libexec/PlistBuddy -c 'Print :DSDPancakeTestRoot' "$plist_path" >/dev/null 2>&1 \
        || /usr/libexec/PlistBuddy -c 'Print :DSDPancakeDSHHome' "$plist_path" >/dev/null 2>&1 \
        || /usr/libexec/PlistBuddy -c 'Print :DSDPancakeDownloadsDirectory' "$plist_path" >/dev/null 2>&1; then
        print -u2 "正式 App 中残留了 Test 端口、DSH_HOME 或下载目录。"
        exit 1
    fi
fi

if [[ "$bundle_icon_name" != "PancakeAppIcon" ]]; then
    print -u2 "bundle 主图标资源键不正确：$bundle_icon_name"
    exit 1
fi

if [[ "$automatic_termination" != "false" || "$sudden_termination" != "false" ]]; then
    print -u2 "自动或突然终止配置不符合生命周期约束。"
    exit 1
fi

if /usr/bin/find "$app_path" -type f \( -iname 'dsh' -o -iname 'node' \) -print -quit | /usr/bin/grep -q .; then
    print -u2 "App 包中发现不应捆绑的 DSH 或 Node.js 可执行文件。"
    exit 1
fi

unexpected_macos_executable=$(/usr/bin/find "$app_path/Contents/MacOS" -type f ! -name 'DSHDesktop' -print -quit)
if [[ -n "$unexpected_macos_executable" ]]; then
    print -u2 "App 包中发现不应发行的额外可执行文件：$unexpected_macos_executable"
    exit 1
fi

# Release bundle 只有主可执行文件、Info.plist、两套图标、清单声明的 App 私有插件，
# 以及 SwiftTerm 唯一必要的 Metal shader。下面的全局文件、目录、链接与特殊节点
# 白名单仍逐项穷举；插件清单只消除四份同构规则，不放宽发行边界。

if /usr/bin/find "$swifterm_bundle_dir" -type f ! -path "$swifterm_shader" -print -quit | /usr/bin/grep -q .; then
    print -u2 "SwiftTerm 资源目录中发现不属于发行白名单的文件。"
    exit 1
fi

unexpected_swifterm_entry=$(/usr/bin/find "$swifterm_bundle_dir" -mindepth 1 -maxdepth 1 ! -name 'Shaders.metal' -print -quit)
if [[ -n "$unexpected_swifterm_entry" ]]; then
    print -u2 "SwiftTerm 资源目录中发现不属于发行白名单的入口：$unexpected_swifterm_entry"
    exit 1
fi

unexpected_swifterm_link=$(/usr/bin/find "$swifterm_bundle_dir" -type l -print -quit)
if [[ -n "$unexpected_swifterm_link" ]]; then
    print -u2 "SwiftTerm 资源目录中不应包含符号链接：$unexpected_swifterm_link"
    exit 1
fi

typeset -A allowed_bundle_files
for allowed_file in \
    "$plist_path" \
    "$executable_path" \
    "$app_icon_path" \
    "$dock_icon_path" \
    "$signature_manifest_path" \
    "${plugin_bundle_files[@]}" \
    "$swifterm_shader"; do
    allowed_bundle_files[$allowed_file]=1
done

unexpected_bundle_file=""
while IFS= read -r -d $'\0' candidate_file; do
    if [[ -z "${allowed_bundle_files[$candidate_file]-}" ]]; then
        unexpected_bundle_file="$candidate_file"
        break
    fi
done < <(/usr/bin/find "$app_path/Contents" -type f -print0)
if [[ -n "$unexpected_bundle_file" ]]; then
    print -u2 "App 包中发现不属于薄壳白名单的文件：$unexpected_bundle_file"
    exit 1
fi

unexpected_bundle_link=$(/usr/bin/find "$app_path/Contents" -type l -print -quit)
if [[ -n "$unexpected_bundle_link" ]]; then
    print -u2 "App 包中发现不属于薄壳白名单的符号链接：$unexpected_bundle_link"
    exit 1
fi

unexpected_bundle_node=$(/usr/bin/find "$app_path/Contents" ! -type f ! -type d ! -type l -print -quit)
if [[ -n "$unexpected_bundle_node" ]]; then
    print -u2 "App 包中发现不属于薄壳白名单的特殊节点：$unexpected_bundle_node"
    exit 1
fi

typeset -A allowed_bundle_directories
for allowed_directory in \
    "$app_path/Contents" \
    "$app_path/Contents/MacOS" \
    "$app_path/Contents/Resources" \
    "${plugin_bundle_directories[@]}" \
    "$app_path/Contents/Resources/SwiftTerm_SwiftTerm.bundle" \
    "$app_path/Contents/_CodeSignature"; do
    allowed_bundle_directories[$allowed_directory]=1
done

unexpected_bundle_directory=""
while IFS= read -r -d $'\0' candidate_directory; do
    if [[ -z "${allowed_bundle_directories[$candidate_directory]-}" ]]; then
        unexpected_bundle_directory="$candidate_directory"
        break
    fi
done < <(/usr/bin/find "$app_path/Contents" -type d -print0)
if [[ -n "$unexpected_bundle_directory" ]]; then
    print -u2 "App 包中发现不属于薄壳白名单的目录：$unexpected_bundle_directory"
    exit 1
fi

print "PASS: bundle ID = $bundle_identifier"
print "PASS: version/build = $version/$build_number"
print "PASS: architecture = $(/usr/bin/lipo -archs "$executable_path")"
print "PASS: bundle 已通过本机 ad-hoc 签名校验，且仅含 DSD Pancake 主可执行文件、Info.plist、图标、${#plugin_rows[@]} 个清单内 App 私有插件与 SwiftTerm Metal 资源；未捆绑 DSH、Node.js、第三方插件、网页资源或测试夹具，且 automatic/sudden termination 已关闭"
