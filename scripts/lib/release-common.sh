#!/bin/bash
# 供打包与发布入口共用；兼容 macOS 自带的 Bash 3.2。

fail() {
    printf '错误：%s\n' "$*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "缺少命令：$1"
}

read_project_version() {
    local project="$REPO_ROOT/MakerShelf.xcodeproj/project.pbxproj"
    [[ -f "$project" ]] || fail "找不到 MakerShelf 工程。"

    # 同时读取 Debug / Release；有多个不同值时，下面的格式校验会拒绝发布。
    VERSION="$(sed -nE 's/.*MARKETING_VERSION[[:space:]]*=[[:space:]]*"?([0-9.]+)"?;.*/\1/p' "$project" | sort -u)"
    BUILD_NUMBER="$(sed -nE 's/.*CURRENT_PROJECT_VERSION[[:space:]]*=[[:space:]]*"?([0-9]+)"?;.*/\1/p' "$project" | sort -u)"
    [[ "$VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || fail "工程版本缺失、格式不正确或 Debug / Release 不一致。"
    [[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]] || fail "构建号缺失或 Debug / Release 不一致。"
}

check_expected_version() {
    [[ -z "$1" || "$1" == "$VERSION" ]] || fail "要求版本 $1 与工程版本 $VERSION 不一致，请先更新工程。"
}
