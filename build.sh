#!/bin/zsh
set -euo pipefail

# 用法：
#   ./build.sh               运行测试 → 构建 → 生成 .app、.zip 和 .dmg（在 ../../outputs）
#   ./build.sh --install     同上，并安装到“应用程序”文件夹，自动退出旧版、打开新版
#   ./build.sh --release     同上，并用 gh 发布到 GitHub Releases（需已安装并登录 GitHub CLI）
#   ./build.sh --skip-tests  跳过测试
#   参数可以组合，例如：./build.sh --install --release

INSTALL=0
RELEASE=0
SKIP_TESTS=0
for arg in "$@"; do
  case "${arg}" in
    --install) INSTALL=1 ;;
    --release) RELEASE=1 ;;
    --skip-tests) SKIP_TESTS=1 ;;
    -h|--help) sed -n '4,9p' "$0"; exit 0 ;;
    *) echo "未知参数：${arg}（可用 --install、--release、--skip-tests）"; exit 1 ;;
  esac
done

SCRIPT_DIR="${0:A:h}"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${SCRIPT_DIR}/Info.plist")"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${SCRIPT_DIR}/Info.plist")"
OUTPUT_DIR="${SCRIPT_DIR}/../../outputs"
APP_DIR="${OUTPUT_DIR}/KongBabel.app"
DMG_NAME="KongBabel-${VERSION}-macOS.dmg"
STAGING_ROOT="$(mktemp -d /private/tmp/kong-build.XXXXXX)"
trap 'rm -rf "${STAGING_ROOT}"' EXIT
STAGING_APP_DIR="${STAGING_ROOT}/KongBabel.app"
CONTENTS_DIR="${STAGING_APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
MODULE_CACHE_DIR="${SCRIPT_DIR}/.build/ModuleCache"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"

if [[ ! -x "${SCRIPT_DIR}/.downloads/mihomo-arm64" || ! -x "${SCRIPT_DIR}/.downloads/mihomo-amd64" ]]; then
  "${SCRIPT_DIR}/download-core.sh"
fi

# ---------------------------------------------------------------- 测试
if (( ! SKIP_TESTS )); then
  echo "==> 运行测试"
  if ! zsh "${SCRIPT_DIR}/test.sh"; then
    echo ""
    echo "✗ 测试未通过，已停止构建。修复后重试，或用 ./build.sh --skip-tests 跳过测试。"
    exit 1
  fi
fi

# ---------------------------------------------------------------- 编译
echo "==> 构建 KongBabel ${VERSION}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}" "${MODULE_CACHE_DIR}" "${OUTPUT_DIR}"
cp -X "${SCRIPT_DIR}/Info.plist" "${CONTENTS_DIR}/Info.plist"

for arch in arm64 x86_64; do
  xcrun swiftc \
    "${SCRIPT_DIR}"/Sources/AeroClash/*.swift \
    -o "${SCRIPT_DIR}/.build/KongBabel-${arch}" \
    -framework SwiftUI \
    -framework AppKit \
    -framework ServiceManagement \
    -framework CoreImage \
    -framework Security \
    -framework Network \
    -framework Carbon \
    -framework CoreWLAN \
    -framework CoreLocation \
    -parse-as-library \
    -sdk "${SDK_PATH}" \
    -module-cache-path "${MODULE_CACHE_DIR}" \
    -target "${arch}-apple-macos13.0" \
    -O
done

lipo -create \
  "${SCRIPT_DIR}/.build/KongBabel-arm64" \
  "${SCRIPT_DIR}/.build/KongBabel-x86_64" \
  -output "${MACOS_DIR}/KongBabel"

sips -z 1024 1024 "${SCRIPT_DIR}/Assets/KongBabelIcon.png" --out "${SCRIPT_DIR}/.build/AppIcon.png" >/dev/null
sips -z 22 22 "${SCRIPT_DIR}/Assets/KongBabelMenuBarIcon.png" --out "${SCRIPT_DIR}/.build/MenuBarIcon.png" >/dev/null
sips -z 44 44 "${SCRIPT_DIR}/Assets/KongBabelMenuBarIcon.png" --out "${SCRIPT_DIR}/.build/MenuBarIcon@2x.png" >/dev/null

cp -X "${SCRIPT_DIR}/.build/AppIcon.png" "${RESOURCES_DIR}/AppIcon.png"
cp -X "${SCRIPT_DIR}/.build/MenuBarIcon.png" "${RESOURCES_DIR}/MenuBarIcon.png"
cp -X "${SCRIPT_DIR}/.build/MenuBarIcon@2x.png" "${RESOURCES_DIR}/MenuBarIcon@2x.png"
lipo -create \
  "${SCRIPT_DIR}/.downloads/mihomo-arm64" \
  "${SCRIPT_DIR}/.downloads/mihomo-amd64" \
  -output "${RESOURCES_DIR}/mihomo"
chmod +x "${RESOURCES_DIR}/mihomo"
cp -X "${SCRIPT_DIR}/Mihomo-NOTICE.txt" "${RESOURCES_DIR}/Mihomo-NOTICE.txt"
cp -X "${SCRIPT_DIR}/Mihomo-LICENSE.txt" "${RESOURCES_DIR}/Mihomo-LICENSE.txt"
xattr -cr "${STAGING_APP_DIR}"
codesign --force --deep --sign - "${STAGING_APP_DIR}" >/dev/null

# ---------------------------------------------------------------- 输出 .app / .zip / .dmg
ditto -c -k --sequesterRsrc --keepParent "${STAGING_APP_DIR}" "${STAGING_ROOT}/KongBabel-macOS.zip"
if [[ -e "${APP_DIR}" ]]; then
  rm -rf "${APP_DIR}"
fi
ditto --norsrc --noextattr --noacl "${STAGING_APP_DIR}" "${APP_DIR}"
xattr -cr "${APP_DIR}"
codesign --force --deep --sign - "${APP_DIR}" >/dev/null
cp -X "${STAGING_ROOT}/KongBabel-macOS.zip" "${OUTPUT_DIR}/KongBabel-macOS.zip"

echo "==> 生成 ${DMG_NAME}"
DMG_STAGE="${STAGING_ROOT}/dmg"
mkdir -p "${DMG_STAGE}"
ditto "${STAGING_APP_DIR}" "${DMG_STAGE}/KongBabel.app"
ln -s /Applications "${DMG_STAGE}/Applications"
hdiutil create -volname "KongBabel ${VERSION}" -srcfolder "${DMG_STAGE}" -ov -format UDZO "${OUTPUT_DIR}/${DMG_NAME}" >/dev/null

echo "✓ 已生成："
echo "   ${APP_DIR}"
echo "   ${OUTPUT_DIR}/KongBabel-macOS.zip"
echo "   ${OUTPUT_DIR}/${DMG_NAME}"

# ---------------------------------------------------------------- 安装
if (( INSTALL )); then
  echo "==> 安装到 /Applications"
  if pgrep -xq KongBabel; then
    osascript -e "tell application id \"${BUNDLE_ID}\" to quit" >/dev/null 2>&1 || true
    for i in {1..20}; do
      pgrep -xq KongBabel || break
      sleep 0.5
    done
    if pgrep -xq KongBabel; then
      pkill -x KongBabel || true
      sleep 1
    fi
  fi
  rm -rf /Applications/KongBabel.app
  ditto "${APP_DIR}" /Applications/KongBabel.app
  xattr -cr /Applications/KongBabel.app
  LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
  if [[ -x "${LSREGISTER}" ]]; then "${LSREGISTER}" -f /Applications/KongBabel.app >/dev/null 2>&1 || true; fi
  touch /Applications/KongBabel.app
  open /Applications/KongBabel.app
  echo "✓ 已安装并打开 /Applications/KongBabel.app"
fi

# ---------------------------------------------------------------- 发布
if (( RELEASE )); then
  if ! command -v gh >/dev/null 2>&1; then
    echo "✗ 未找到 gh 命令。请先安装 GitHub CLI（brew install gh）并运行 gh auth login。"
    exit 1
  fi
  TAG="v${VERSION}"
  echo "==> 发布 ${TAG} 到 GitHub"
  cd "${SCRIPT_DIR}"
  if gh release view "${TAG}" >/dev/null 2>&1; then
    gh release upload "${TAG}" "${OUTPUT_DIR}/${DMG_NAME}" --clobber
  else
    gh release create "${TAG}" "${OUTPUT_DIR}/${DMG_NAME}" --title "KongBabel ${VERSION}" --generate-notes
  fi
  echo "✓ 已发布 ${TAG}"
fi
