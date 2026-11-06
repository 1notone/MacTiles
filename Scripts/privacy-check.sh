#!/usr/bin/env bash
# Looks for personal information and secrets before you publish or push.
#
#   ./Scripts/privacy-check.sh
#
# Checks every file that would be committed (or every file, outside git) for real-looking
# email addresses, home folders, private keys and API tokens, and checks the name and
# email git will put on your commits. Example values (example.com, /Users/me, 192.168.x.x)
# are fine and ignored.
set -uo pipefail
cd "$(dirname "$0")/.."

if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  files=$(git ls-files --cached --others --exclude-standard)
else
  files=$(find . -type f -not -path './.build/*' -not -path './build/*' -not -path './.git/*' | sed 's|^\./||')
fi
files=$(printf '%s\n' "$files" | grep -vE '\.(png|icns|zip|pkg|dmg)$')
problems=0

check() {   # check "<what>" "<regex>" "<allowed regex>"
  local hits
  hits=$(printf '%s\n' "$files" | tr '\n' '\0' | xargs -0 grep -nEI "$2" 2>/dev/null | grep -vE "$3" || true)
  if [ -n "$hits" ]; then
    echo "✗ $1:"
    printf '%s\n' "$hits" | sed 's/^/    /' | head -20
    problems=1
  fi
}

check "Email addresses" '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' \
      '@example\.(com|org)|me@x\.com|noreply@|users\.noreply\.github\.com|Scripts/privacy-check\.sh'
check "Home folders" '/Users/[A-Za-z0-9._-]+|/home/[A-Za-z0-9._-]+' \
      '/Users/me/|/Users/Shared|Scripts/privacy-check\.sh'
check "Private keys" 'BEGIN [A-Z ]*PRIVATE KEY' 'Scripts/privacy-check\.sh'
check "Access tokens" '(ghp|gho|github_pat|glpat|xox[abp])_[A-Za-z0-9_]{16,}|AKIA[0-9A-Z]{16}|sk-[A-Za-z0-9]{20,}' 'Scripts/privacy-check\.sh'
check "Developer ID names" 'Developer ID (Application|Installer): [A-Za-z]' 'Jane Doe|Scripts/privacy-check\.sh'

if [ -z "${CI:-}" ] && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  name=$(git config user.name || true)
  email=$(git config user.email || true)
  echo "Commits will be signed as: ${name:-<not set>} <${email:-not set}>"
  case "$email" in
    *@users.noreply.github.com) ;;
    *) echo "! Your commit email isn't a GitHub no-reply address. See RELEASING.md → Publishing on GitHub."; problems=1 ;;
  esac
fi

if [ "$problems" = 0 ]; then echo "✓ Nothing personal found."; else exit 1; fi
