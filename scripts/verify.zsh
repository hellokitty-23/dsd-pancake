#!/bin/zsh

set -euo pipefail

script_dir=${0:A:h}
project_root=${script_dir:h}

# 受控验证不探测用户正在使用的 127.0.0.1:3080 服务。
/usr/bin/env node "$script_dir/verify-notification-plugin.mjs"
/usr/bin/env node "$script_dir/verify-terminal-plugin.mjs"
/usr/bin/swift build -c release --product DSHDesktop --package-path "$project_root"
exec /usr/bin/swift run -c release --package-path "$project_root" DSHDesktopVerification --skip-current-external-probe "$@"
