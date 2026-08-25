#!/bin/zsh

set -euo pipefail

if [[ $# -ne 1 ]]; then
    print -u2 "用法：$0 '/绝对路径/DSD Pancake.app'"
    exit 64
fi

app_path=${1:A}
plist_path="$app_path/Contents/Info.plist"
executable_path="$app_path/Contents/MacOS/DSHDesktop"
icon_path="$app_path/Contents/Resources/AppIcon.icns"

for required_path in "$plist_path" "$executable_path" "$icon_path"; do
    if [[ ! -e "$required_path" ]]; then
        print -u2 "App 包缺少必需文件：$required_path"
        exit 1
    fi
done

/usr/bin/plutil -lint "$plist_path"
bundle_identifier=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist_path")
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist_path")
build_number=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist_path")
automatic_termination=$(/usr/libexec/PlistBuddy -c 'Print :NSSupportsAutomaticTermination' "$plist_path")
sudden_termination=$(/usr/libexec/PlistBuddy -c 'Print :NSSupportsSuddenTermination' "$plist_path")

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

# 当前薄壳的 Release bundle 只有主可执行文件、Info.plist 和图标。以严格白名单
# 校验全部常规文件和符号链接，避免未来打包脚本意外带入 DSH、Node.js、插件、网页
# 资源或测试夹具，而不是仅靠文件名猜测。
unexpected_bundle_file=$(/usr/bin/find "$app_path/Contents" -type f \
    ! -path "$plist_path" \
    ! -path "$executable_path" \
    ! -path "$icon_path" \
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

print "PASS: bundle ID = $bundle_identifier"
print "PASS: version/build = $version/$build_number"
print "PASS: architecture = $(/usr/bin/lipo -archs "$executable_path")"
print "PASS: bundle 仅含 DSHDesktop、Info.plist 与图标；未捆绑 DSH、Node.js、插件、网页资源或测试夹具，且 automatic/sudden termination 已关闭"
