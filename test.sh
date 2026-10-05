#!/bin/zsh
# 运行 KongBabel 的逻辑测试（订阅解析、运行时配置、网络事件、节点稳定性、版本比较、快捷键）。
# 用法：./test.sh        build.sh 默认会在构建前自动运行它。
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
SRC="${SCRIPT_DIR}/Sources/AeroClash"
OUT="${SCRIPT_DIR}/.build/tests"
MODULE_CACHE_DIR="${SCRIPT_DIR}/.build/ModuleCache"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
ARCH="$(uname -m)"
WORK="$(mktemp -d /private/tmp/kongbabel-tests.XXXXXX)"
trap 'rm -rf "${WORK}"' EXIT
mkdir -p "${OUT}" "${MODULE_CACHE_DIR}"

# 测试用到的非界面源码（不包含 SwiftUI 页面和 AppModel）
LOGIC_SOURCES=(
  AdvancedSettings Runtime SubscriptionFormatter SubscriptionDownloader Models
  AppInfo NetworkWatchdog NetworkEvents NodeStats UpdateChecker GlobalHotKeys
)
SOURCES=()
for name in "${LOGIC_SOURCES[@]}"; do SOURCES+=("${SRC}/${name}.swift"); done

if [[ "${ARCH}" == "arm64" ]]; then CORE="${SCRIPT_DIR}/.downloads/mihomo-arm64"; else CORE="${SCRIPT_DIR}/.downloads/mihomo-amd64"; fi
if [[ ! -x "${CORE}" ]]; then
  "${SCRIPT_DIR}/download-core.sh"
fi

run_test() {
  local name="$1"
  echo "▶ ${name}"
  xcrun swiftc \
    "${SCRIPT_DIR}/Tests/${name}.swift" \
    "${SOURCES[@]}" \
    -o "${OUT}/${name}" \
    -framework AppKit -framework Security -framework Network -framework Carbon \
    -parse-as-library \
    -sdk "${SDK_PATH}" \
    -module-cache-path "${MODULE_CACHE_DIR}" \
    -target "${ARCH}-apple-macos13.0"
  "${OUT}/${name}" "${CORE}" "${WORK}/${name}"
  echo "✓ ${name}"
}

run_test NetworkLogicTests
run_test SubscriptionFormatterTests
run_test AdvancedSettingsTests

echo "全部测试通过"
