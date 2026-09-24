#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/release-common.sh"

usage() {
    cat <<'EOF'
用法：bash scripts/release.sh [--version 2.1] [--remote origin] [--branch main] [--push]

默认只做本地检查和显示发布计划，不联网、不创建标签、不推送。
  --version 版本   要求工程版本与指定值一致，不自动修改版本号。
  --remote 名称    已配置的 Git 远端，默认 origin。
  --branch 名称    要发布的当前分支，默认 main。
  --push          检查远端标签后，创建本地标签并原子推送分支与标签。
  -h, --help      显示帮助。

要求工作区干净，并准备 .github/release-notes/v版本.md 与 CHANGELOG 版本条目。
脚本不会自动暂存或提交；推送标签后由 GitHub Actions 构建、打包并创建 Release。
EOF
}

expected_version=""
remote=origin
branch=main
push=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --version|--remote|--branch)
            [[ $# -ge 2 && -n "$2" && "$2" != -* ]] || fail "$1 需要一个参数。"
            case "$1" in
                --version) expected_version="$2" ;;
                --remote) remote="$2" ;;
                --branch) branch="$2" ;;
            esac
            shift 2
            ;;
        --push) push=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) fail "未知参数：$1；使用 --help 查看用法。" ;;
    esac
done

require_command git
cd "$REPO_ROOT"
read_project_version
check_expected_version "$expected_version"
tag="v$VERSION"
notes=".github/release-notes/$tag.md"
git check-ref-format "refs/heads/$branch" >/dev/null || fail "分支名称不合法：$branch"
current_branch="$(git symbolic-ref --quiet --short HEAD)" || fail "当前处于分离 HEAD，请先切换到发布分支。"
[[ "$current_branch" == "$branch" ]] || fail "请先切换到 $branch，当前分支为 $current_branch。"

# 仅接受配置过的单一推送地址，避免把标签检查与实际推送发往不同仓库。
push_url="$(git remote get-url --push --all "$remote")" || fail "找不到远端：$remote"
[[ -n "$push_url" && "$push_url" != *$'\n'* ]] || fail "发布远端必须只有一个推送地址。"
status="$(git status --porcelain --untracked-files=all)"
[[ -z "$status" ]] || fail "存在未提交或未跟踪的文件。请先自行整理并提交；此脚本不会自动提交。"
[[ -s "$notes" ]] || fail "缺少或尚未填写发布说明：$notes"
grep -Fq "## [$VERSION] - " CHANGELOG.md || fail "请在 CHANGELOG.md 中增加 $VERSION 的正式版本条目和日期。"
git ls-files --error-unmatch "$notes" .github/workflows/release.yml scripts/package.sh scripts/lib/release-common.sh >/dev/null || fail "发布资料、打包脚本和工作流必须已提交。"

# 忽略规则不能排除已经提交的文件；再次检查本项目明确不公开的目录。
while IFS= read -r -d '' tracked_path; do
    case "$tracked_path" in
        docs/发布流程.md|docs/功能梳理.md) ;;
        docs/*|prototype/*|index.html|build/*|dist/*|.release/*|.agents/*|.codex/*|AGENTS.md|CLAUDE.md)
            fail "发现不应发布的已跟踪文件：$tracked_path；请先取消跟踪并提交整理结果。"
            ;;
    esac
done < <(git ls-files -z)

commit="$(git rev-parse HEAD)"
if git show-ref --verify --quiet "refs/tags/$tag"; then
    tag_commit="$(git rev-parse "refs/tags/$tag^{commit}")"
    [[ "$tag_commit" == "$commit" ]] || fail "本地标签 $tag 指向其他提交；请使用新版本，不覆盖已有标签。"
fi

printf '发布计划：\n  版本：%s（构建 %s）\n  分支：%s → %s/%s\n  提交：%s\n  标签：%s\n  说明：%s\n' \
    "$VERSION" "$BUILD_NUMBER" "$branch" "$remote" "$branch" "$commit" "$tag" "$notes"
if [[ "$push" != true ]]; then
    printf '\n本地检查通过；尚未检查远端。添加 --push 后将推送，并触发 GitHub Actions 发布。\n'
    exit 0
fi

# 使用推送地址检查标签；网络或权限错误不能误判成“标签不存在”。
if git ls-remote --exit-code --tags "$push_url" "refs/tags/$tag" >/dev/null; then
    fail "远端已存在 $tag，不重复发布或覆盖。新版本请递增版本号；失败的构建请在 Actions 中重新运行。"
else
    remote_status=$?
    [[ $remote_status -eq 2 ]] || fail "无法检查远端标签，请确认网络和 Git 推送权限。"
fi

# 防止检查期间用户切换分支或提交，确保推送与刚刚检查的源码完全一致。
[[ "$(git symbolic-ref --quiet --short HEAD)" == "$branch" && "$(git rev-parse HEAD)" == "$commit" ]] || fail "检查期间当前分支或提交发生变化，请重新运行。"
[[ -z "$(git status --porcelain --untracked-files=all)" ]] || fail "检查期间工作区发生变化，请整理后重新运行。"
if ! git show-ref --verify --quiet "refs/tags/$tag"; then
    git tag -a "$tag" "$commit" -m "发布 MakerShelf $VERSION"
fi
[[ "$(git rev-parse "refs/tags/$tag^{commit}")" == "$commit" ]] || fail "检查期间本地标签发生变化，请重新确认后发布。"

# 不强制推送；分支非快进、标签冲突或权限失败时，远端两项均不更新。
if ! git -c push.followTags=false push --atomic "$remote" "$commit:refs/heads/$branch" "refs/tags/$tag:refs/tags/$tag"; then
    fail "推送失败。本地 $tag 标签保留，可排除问题后重试；脚本不会覆盖远端或自动回滚标签。"
fi
printf '\n已推送 %s 和 %s。请在 GitHub Actions 查看构建结果，成功后 Release 才会提供安装包。\n' "$branch" "$tag"
