#!/usr/bin/env bash
set -euo pipefail

required_files=(
  "AGENTS.md"
  "CLAUDE.md"
  "ai/process/workflow.md"
  "ai/process/context-protocol.md"
  "ai/process/definition-of-ready.md"
  "ai/process/definition-of-done.md"
  "ai/process/review-gates.md"
  "ai/process/kanban.md"
  "ai/context/design-system.md"
  "ai/artifacts/README.md"
  "ai/templates/feature-spec.md"
  "ai/templates/screen-spec.md"
  "ai/templates/task-card.md"
  "ai/templates/verification-report.md"
  "ai/checklists/security-checklist.md"
  "ai/checklists/testing-checklist.md"
  "ai/checklists/design-review-checklist.md"
  "ai/skills/project-kickoff.md"
  "ai/skills/design-craft.md"
  "ai/skills/project-search.md"
  "ai/skills/spec-interrogation.md"
  "ai/skills/ui-mockup-gate.md"
  "ai/skills/implementation-plan.md"
  "ai/skills/security-maintainability-review.md"
  "ai/skills/test-verification.md"
)

missing=0

for file in "${required_files[@]}"; do
  if [[ ! -f "$file" ]]; then
    echo "missing: $file"
    missing=1
  fi
done

# ai/skills/ 是每个 .claude/skills 薄 stub 的正本内容。若某个 skill 只存在于
# 一边，stub 就会指向一个不存在的文件。
# 注：上游还检查 .codex/skills，本 fork 已删除 Codex 支持，故不再检查。
skill_names=()
for f in ai/skills/*.md; do
  skill_names+=("$(basename "${f%.md}")")
done

for name in "${skill_names[@]}"; do
  if [[ ! -f ".claude/skills/$name/SKILL.md" ]]; then
    echo "missing: .claude/skills/$name/SKILL.md (ai/skills/$name.md 没有对应的 Claude Code stub)"
    missing=1
  fi
done

# 反向检查只是警告，不是失败：本项目可以有自己的、不走 ai/skills 正本机制的
# 项目级 skill（例如 board-card 之外的临时 skill）。上游在这里 exit 1，会让
# 任何加了自有 skill 的项目直接崩掉。
for dir in .claude/skills/*/; do
  [[ -d "$dir" ]] || continue
  name="$(basename "$dir")"
  if [[ ! -f "ai/skills/$name.md" ]]; then
    echo "warn: $dir 没有对应的 ai/skills/$name.md（若这是项目自有 skill 则可忽略）"
  fi
done

if [[ "$missing" -ne 0 ]]; then
  echo "governance kit check failed"
  exit 1
fi

echo "governance kit check passed"

