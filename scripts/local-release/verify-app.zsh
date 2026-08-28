#!/bin/zsh

set -euo pipefail

if [[ $# -ne 1 ]]; then
    print -u2 "用法：$0 '/绝对路径/DSD Pancake.app'"
    exit 64
fi

app_path=${1:A}
plist_path="$app_path/Contents/Info.plist"
executable_path="$app_path/Contents/MacOS/DSHDesktop"
app_icon_path="$app_path/Contents/Resources/PancakeAppIcon.icns"
dock_icon_path="$app_path/Contents/Resources/DockIcon.icns"
signature_manifest_path="$app_path/Contents/_CodeSignature/CodeResources"
notification_plugin_dir="$app_path/Contents/Resources/DSHNotifications"
notification_plugin_package="$notification_plugin_dir/package.json"
notification_plugin_patch="$notification_plugin_dir/cordis.patch.yml"
notification_plugin_host="$notification_plugin_dir/lib/index.js"
notification_plugin_client="$notification_plugin_dir/lib/client.js"
terminal_plugin_dir="$app_path/Contents/Resources/DSHTerminal"
terminal_plugin_package="$terminal_plugin_dir/package.json"
terminal_plugin_patch="$terminal_plugin_dir/cordis.patch.yml"
terminal_plugin_host="$terminal_plugin_dir/lib/index.js"
terminal_plugin_client="$terminal_plugin_dir/lib/client.js"
operation_folding_plugin_dir="$app_path/Contents/Resources/DSHOperationFolding"
operation_folding_plugin_package="$operation_folding_plugin_dir/package.json"
operation_folding_plugin_patch="$operation_folding_plugin_dir/cordis.patch.yml"
operation_folding_plugin_host="$operation_folding_plugin_dir/lib/index.js"
operation_folding_plugin_client="$operation_folding_plugin_dir/lib/client.js"
swifterm_bundle_dir="$app_path/Contents/Resources/SwiftTerm_SwiftTerm.bundle"
swifterm_shader="$swifterm_bundle_dir/Shaders.metal"

for required_path in \
    "$plist_path" \
    "$executable_path" \
    "$app_icon_path" \
    "$dock_icon_path" \
    "$signature_manifest_path" \
    "$notification_plugin_package" \
    "$notification_plugin_patch" \
    "$notification_plugin_host" \
    "$notification_plugin_client" \
    "$terminal_plugin_package" \
    "$terminal_plugin_patch" \
    "$terminal_plugin_host" \
    "$terminal_plugin_client" \
    "$operation_folding_plugin_package" \
    "$operation_folding_plugin_patch" \
    "$operation_folding_plugin_host" \
    "$operation_folding_plugin_client" \
    "$swifterm_shader"; do
    if [[ ! -f "$required_path" || -L "$required_path" ]]; then
        print -u2 "App 包缺少必需普通文件，或必需路径是符号链接：$required_path"
        exit 1
    fi
done

/usr/bin/plutil -lint "$plist_path"
/usr/bin/codesign --verify --deep --strict --verbose=4 "$app_path"
bundle_identifier=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist_path")
bundle_icon_name=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$plist_path")
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist_path")
build_number=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist_path")
automatic_termination=$(/usr/libexec/PlistBuddy -c 'Print :NSSupportsAutomaticTermination' "$plist_path")
sudden_termination=$(/usr/libexec/PlistBuddy -c 'Print :NSSupportsSuddenTermination' "$plist_path")

if [[ "$bundle_identifier" != "io.github.hellokitty-23.dsd-pancake" ]]; then
    print -u2 "bundle ID 不正确：$bundle_identifier"
    exit 1
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

# Release bundle 只有主可执行文件、Info.plist、两套图标、三个已构建的 App 私有插件，
# 以及 SwiftTerm 唯一必要的 Metal shader。严格白名单避免未来意外带入 DSH、Node.js、
# 第三方插件、网页资源或测试夹具。
if /usr/bin/find "$notification_plugin_dir" -type f \
    ! -path "$notification_plugin_package" \
    ! -path "$notification_plugin_patch" \
    ! -path "$notification_plugin_host" \
    ! -path "$notification_plugin_client" \
    -print -quit | /usr/bin/grep -q .; then
    print -u2 "提醒插件目录中发现不属于发行白名单的文件。"
    exit 1
fi

if /usr/bin/find "$notification_plugin_dir" -type d -name node_modules -print -quit | /usr/bin/grep -q .; then
    print -u2 "提醒插件目录中不应包含 node_modules。"
    exit 1
fi

if /usr/bin/find "$terminal_plugin_dir" -type f \
    ! -path "$terminal_plugin_package" \
    ! -path "$terminal_plugin_patch" \
    ! -path "$terminal_plugin_host" \
    ! -path "$terminal_plugin_client" \
    -print -quit | /usr/bin/grep -q .; then
    print -u2 "终端插件目录中发现不属于发行白名单的文件。"
    exit 1
fi

if /usr/bin/find "$terminal_plugin_dir" -type d -name node_modules -print -quit | /usr/bin/grep -q .; then
    print -u2 "终端插件目录中不应包含 node_modules。"
    exit 1
fi

if /usr/bin/find "$operation_folding_plugin_dir" -type f \
    ! -path "$operation_folding_plugin_package" \
    ! -path "$operation_folding_plugin_patch" \
    ! -path "$operation_folding_plugin_host" \
    ! -path "$operation_folding_plugin_client" \
    -print -quit | /usr/bin/grep -q .; then
    print -u2 "操作折叠插件目录中发现不属于发行白名单的文件。"
    exit 1
fi

if /usr/bin/find "$operation_folding_plugin_dir" -type d -name node_modules -print -quit | /usr/bin/grep -q .; then
    print -u2 "操作折叠插件目录中不应包含 node_modules。"
    exit 1
fi

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

verify_plugin_package_name() {
    local package_path=$1
    local expected_name=$2
    local label=$3
    local actual_name

    if ! actual_name=$(/usr/bin/plutil -extract name raw -expect string -o - "$package_path" 2>/dev/null); then
        print -u2 "$label package.json 无法解析，或 name 不是字符串。"
        exit 1
    fi
    if [[ "$actual_name" != "$expected_name" ]]; then
        print -u2 "$label package.json 身份不正确：$actual_name"
        exit 1
    fi
}

verify_plugin_package_name \
    "$notification_plugin_package" \
    "@dsd-pancake/dsh-desktop-notifications" \
    "提醒插件"
verify_plugin_package_name \
    "$terminal_plugin_package" \
    "@dsd-pancake/dsh-desktop-terminal" \
    "终端插件"
verify_plugin_package_name \
    "$operation_folding_plugin_package" \
    "@dsd-pancake/dsh-desktop-operation-folding" \
    "操作折叠插件"

unexpected_bundle_file=$(/usr/bin/find "$app_path/Contents" -type f \
    ! -path "$plist_path" \
    ! -path "$executable_path" \
    ! -path "$app_icon_path" \
    ! -path "$dock_icon_path" \
    ! -path "$signature_manifest_path" \
    ! -path "$notification_plugin_package" \
    ! -path "$notification_plugin_patch" \
    ! -path "$notification_plugin_host" \
    ! -path "$notification_plugin_client" \
    ! -path "$terminal_plugin_package" \
    ! -path "$terminal_plugin_patch" \
    ! -path "$terminal_plugin_host" \
    ! -path "$terminal_plugin_client" \
    ! -path "$operation_folding_plugin_package" \
    ! -path "$operation_folding_plugin_patch" \
    ! -path "$operation_folding_plugin_host" \
    ! -path "$operation_folding_plugin_client" \
    ! -path "$swifterm_shader" \
    -print -quit)
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

unexpected_bundle_directory=$(/usr/bin/find "$app_path/Contents" -type d \
    ! -path "$app_path/Contents" \
    ! -path "$app_path/Contents/MacOS" \
    ! -path "$app_path/Contents/Resources" \
    ! -path "$app_path/Contents/Resources/DSHNotifications" \
    ! -path "$app_path/Contents/Resources/DSHNotifications/lib" \
    ! -path "$app_path/Contents/Resources/DSHTerminal" \
    ! -path "$app_path/Contents/Resources/DSHTerminal/lib" \
    ! -path "$app_path/Contents/Resources/DSHOperationFolding" \
    ! -path "$app_path/Contents/Resources/DSHOperationFolding/lib" \
    ! -path "$app_path/Contents/Resources/SwiftTerm_SwiftTerm.bundle" \
    ! -path "$app_path/Contents/_CodeSignature" \
    -print -quit)
if [[ -n "$unexpected_bundle_directory" ]]; then
    print -u2 "App 包中发现不属于薄壳白名单的目录：$unexpected_bundle_directory"
    exit 1
fi

print "PASS: bundle ID = $bundle_identifier"
print "PASS: version/build = $version/$build_number"
print "PASS: architecture = $(/usr/bin/lipo -archs "$executable_path")"
print "PASS: bundle 已通过本机 ad-hoc 签名校验，且仅含 DSD Pancake 主可执行文件、Info.plist、图标、三个 App 私有插件与 SwiftTerm Metal 资源；未捆绑 DSH、Node.js、第三方插件、网页资源或测试夹具，且 automatic/sudden termination 已关闭"
