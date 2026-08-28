#!/bin/zsh

set -euo pipefail

script_dir=${0:A:h}
project_root=${script_dir:h}
plugin_catalog="$script_dir/private-plugin-catalog.mjs"
plugin_metadata_verifier="$script_dir/verify-private-plugin-metadata.mjs"
temporary_dir="$(/usr/bin/mktemp -d /tmp/dsd-pancake-verify.XXXXXX)"

cleanup() {
    /bin/rm -rf -- "$temporary_dir"
}
trap cleanup EXIT

# 受控验证不探测用户正在使用的 127.0.0.1:3080 服务。
/usr/bin/env node "$plugin_metadata_verifier" --source-root "$project_root"
/usr/bin/env node "$plugin_metadata_verifier" --self-test
plugin_verifiers=("${(@f)$(/usr/bin/env node "$plugin_catalog" verifiers)}")
for relative_verifier in "${plugin_verifiers[@]}"; do
    /usr/bin/env node "$project_root/$relative_verifier"
done
/usr/bin/swift build \
    -c release \
    --product DSHDesktop \
    --package-path "$project_root" \
    --scratch-path "$temporary_dir/swift-build"
/usr/bin/swift run \
    -c release \
    --package-path "$project_root" \
    --scratch-path "$temporary_dir/swift-build" \
    DSHDesktopVerification \
    --skip-current-external-probe \
    "$@"
