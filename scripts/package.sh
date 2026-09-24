#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/release-common.sh"

usage() {
    cat <<'EOF'
用法：bash scripts/package.sh [--version 2.1] [--output 目录]

以 Release 配置构建 Apple Silicon / Intel 通用 App，生成未签名 ZIP 和 SHA-256。
  --version 版本   要求工程版本与指定值一致，不自动修改版本号。
  --output 目录    输出目录，默认仓库的 dist/；相对路径以当前目录为基准。
  -h, --help       显示帮助。

产物包含 App、LICENSE、NOTICE；同版本产物会在构建成功后替换。
此脚本会编译，但不运行测试、不安装 App、不修改 Git、不上传文件。
EOF
}

expected_version=""
output_dir="$REPO_ROOT/dist"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --version|--output)
            [[ $# -ge 2 && -n "$2" && "$2" != -* ]] || fail "$1 需要一个参数。"
            if [[ "$1" == --version ]]; then expected_version="$2"; else output_dir="$2"; fi
            shift 2
            ;;
        -h|--help) usage; exit 0 ;;
        *) fail "未知参数：$1；使用 --help 查看用法。" ;;
    esac
done

read_project_version
check_expected_version "$expected_version"
[[ "$(uname -s)" == Darwin ]] || fail "打包需要 macOS 和完整 Xcode。"
for command_name in xcodebuild xcrun ditto shasum tee; do require_command "$command_name"; done
# 与工程构建阶段一致，使用 Apple 工具入口，不依赖终端 PATH 中的同名命令。
/usr/bin/xcodebuild -version >/dev/null || fail "请安装完整 Xcode，并将其设为当前开发工具。"
[[ -f "$REPO_ROOT/LICENSE" && -f "$REPO_ROOT/NOTICE" ]] || fail "缺少 LICENSE 或 NOTICE。"

mkdir -p "$output_dir" "$REPO_ROOT/build/logs"
output_dir="$(cd "$output_dir" && pwd)"
log_file="$REPO_ROOT/build/logs/package-$(date '+%Y%m%d-%H%M%S')-$$.log"
# 每次使用独立构建目录，避免复用旧 App，也避免同时打包时互相清理产物。
work_dir="$(mktemp -d "$REPO_ROOT/build/package.XXXXXX")"
cleanup() {
    local status=$?
    trap - EXIT
    rm -rf -- "$work_dir"
    if [[ $status -ne 0 ]]; then printf '打包未完成。构建日志：%s\n' "$log_file" >&2; fi
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

printf '开始打包 MakerShelf %s（构建 %s）\n' "$VERSION" "$BUILD_NUMBER"
/usr/bin/xcodebuild \
    -project "$REPO_ROOT/MakerShelf.xcodeproj" \
    -scheme MakerShelf \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$work_dir/DerivedData" \
    ARCHS="arm64 x86_64" \
    ONLY_ACTIVE_ARCH=NO \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    build 2>&1 | tee "$log_file"

app="$work_dir/DerivedData/Build/Products/Release/MakerShelf.app"
[[ -d "$app" ]] || fail "没有找到构建完成的 MakerShelf.app。"
app_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
app_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")"
[[ "$app_version" == "$VERSION" && "$app_build" == "$BUILD_NUMBER" ]] || fail "App 内的版本号与工程不一致。"
# 主程序与登录辅助程序都必须包含两种架构，避免 Intel 用户下载后无法登录。
for executable in MakerShelf MakerShelfLogin; do
    /usr/bin/xcrun lipo "$app/Contents/MacOS/$executable" -verify_arch arm64 x86_64 || fail "$executable 缺少通用架构。"
done

package_name="MakerShelf-${VERSION}-unsigned-macOS.zip"
staging="$work_dir/MakerShelf-${VERSION}"
mkdir -p "$staging"
ditto "$app" "$staging/MakerShelf.app"
cp "$REPO_ROOT/LICENSE" "$REPO_ROOT/NOTICE" "$staging/"
ditto -c -k --sequesterRsrc --keepParent "$staging" "$work_dir/$package_name"
# 校验文件只记录文件名，下载到其他目录后仍可直接使用 shasum -c。
(cd "$work_dir" && shasum -a 256 "$package_name" > "$package_name.sha256")
mv -f "$work_dir/$package_name" "$output_dir/$package_name"
mv -f "$work_dir/$package_name.sha256" "$output_dir/$package_name.sha256"

printf '\n打包完成（未经过 Developer ID 签名或 Apple 公证）：\n%s\n%s\n构建日志：%s\n' \
    "$output_dir/$package_name" "$output_dir/$package_name.sha256" "$log_file"
