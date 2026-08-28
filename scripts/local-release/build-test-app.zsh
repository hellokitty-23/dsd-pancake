#!/bin/zsh

set -euo pipefail

script_dir=${0:A:h}
project_root=${script_dir:h:h}
output_dir="${DSHD_TEST_OUTPUT_DIR:-$project_root/local-test}"
output_dir=${output_dir:A}
service_port="${DSHD_TEST_PORT:-13080}"
bundle_identifier="${DSHD_TEST_BUNDLE_IDENTIFIER:-io.github.hellokitty-23.dsd-pancake.test}"
test_dsh_home="${DSHD_TEST_DSH_HOME:-$output_dir/test-dsh-home}"
test_downloads_directory="${DSHD_TEST_DOWNLOADS_DIR:-$output_dir/test-downloads}"
test_app_version="${DSHD_TEST_APP_VERSION:-}"
app_path="$output_dir/DSD Pancake Test.app"

if [[ "$service_port" != <-> || "$service_port" -lt 1024 || "$service_port" -gt 65535 || "$service_port" -eq 3080 ]]; then
    print -u2 "Test 端口必须是 1024...65535 内且不能为 3080：$service_port"
    exit 64
fi
if /usr/sbin/lsof -nP -iTCP:"$service_port" -sTCP:LISTEN 2>/dev/null | /usr/bin/grep -q .; then
    print -u2 "Test 端口已被占用，不会触碰该 listener：$service_port"
    exit 2
fi

DSHD_TEST_MODE=1 \
DSHD_OUTPUT_DIR="$output_dir" \
DSHD_APP_DISPLAY_NAME="DSD Pancake Test" \
DSHD_BUNDLE_IDENTIFIER="$bundle_identifier" \
DSHD_SERVICE_PORT="$service_port" \
DSHD_TEST_DSH_HOME="$test_dsh_home" \
DSHD_TEST_DOWNLOADS_DIR="$test_downloads_directory" \
DSHD_TEST_APP_VERSION="$test_app_version" \
    /bin/zsh "$script_dir/build-app.zsh"

DSHD_EXPECTED_TEST_MODE=1 \
DSHD_EXPECTED_BUNDLE_IDENTIFIER="$bundle_identifier" \
DSHD_EXPECTED_APP_VERSION="$test_app_version" \
    /bin/zsh "$script_dir/verify-app.zsh" "$app_path"

print "隔离 Test App 已生成并通过 bundle 校验：$app_path"
print "Test endpoint（服务端点）：http://127.0.0.1:$service_port/"
print "Test DSH_HOME：$test_dsh_home"
print "Test 下载目录：$test_downloads_directory"
if [[ -n "$test_app_version" ]]; then
    print "Test 版本覆盖：$test_app_version（仅用于更新流程验收）"
fi
