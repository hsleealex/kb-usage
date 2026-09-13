#!/bin/bash
# kb-usage 메뉴바 앱 상주 해제.
set -e
LABEL="com.gaedongi.claude-usage-menubar"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
pkill -f "kb-usage-menubar" 2>/dev/null || true
echo "해제 완료."
echo "statusLine 도 빼려면 ~/.claude/settings.json 의 statusLine 블록을 지우세요."
