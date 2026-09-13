#!/bin/bash
# kb-usage 메뉴바 앱을 빌드하고 launchd 에이전트로 상주 등록한다.
set -e

BASE="$(cd "$(dirname "$0")" && pwd)"
LABEL="com.gaedongi.claude-usage-menubar"
PLIST_DST="$HOME/Library/LaunchAgents/$LABEL.plist"

echo "· base : $BASE"

# 1. 빌드
echo "· 빌드…"
swiftc -O "$BASE/menubar.swift" -o "$BASE/kb-usage-menubar"

# 2. plist 설치 (__BASE__ 치환)
mkdir -p "$HOME/Library/LaunchAgents"
sed "s#__BASE__#$BASE#g" "$BASE/$LABEL.plist" > "$PLIST_DST"

# 3. (재)기동
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST_DST"
launchctl kickstart -k "gui/$(id -u)/$LABEL"

sleep 1
if pgrep -f "kb-usage-menubar" >/dev/null; then
  echo "✓ 메뉴바 앱 상주 시작. 로그인하면 자동 실행됩니다."
  echo "  로그: $BASE/menubar.log"
else
  echo "✗ 실행 안 됨. $BASE/menubar.log 확인."
  exit 1
fi
