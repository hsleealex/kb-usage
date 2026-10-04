#!/bin/bash
# kb-usage 메뉴바 앱을 빌드하고 launchd 에이전트로 상주 등록한다.
set -e

BASE="$(cd "$(dirname "$0")" && pwd)"
LABEL="com.gaedongi.claude-usage-menubar"
PLIST_DST="$HOME/Library/LaunchAgents/$LABEL.plist"

echo "· base : $BASE"

# 1. 빌드
echo "· 빌드…"
swiftc -O "$BASE/menubar.swift" -o "$BASE/kb-usage-menubar" \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$BASE/bundle/Info.plist"
# ad-hoc 재서명: 식별자 고정 + Info.plist 묶기 + 요구사항을 식별자 기준으로.
# 링커 서명(기본)은 요구사항이 cdhash 라 재빌드마다 다른 앱이 되고, Info.plist 도 안 묶여
# macOS 가 "Ghostty 제어" 권한 팝업을 못 띄우고 바로 거부(-1743)한다 (2026-10-04 확인).
sign() { codesign --force --sign - --identifier kb-usage-menubar \
  -r='designated => identifier "kb-usage-menubar"' "$1"; }
sign "$BASE/kb-usage-menubar"       # 단독 실행 파일 — CLI 용 (--focus, --render-icon …)
# (Info.plist 를 실행 파일 옆에 두면 codesign 이 레포 폴더 전체를 번들로 보고 봉인한다 → bundle/ 에 둔다)

# 메뉴바 앱은 번들로 띄운다 — 자동화 권한("Ghostty 제어")의 주체가 번들 id 하나로 모인다.
# (번들 없는 실행 파일은 권한이 경로로 기록되고 설정 화면에서 관리가 안 된다)
APP="$BASE/KbUsage.app"
mkdir -p "$APP/Contents/MacOS"
cp "$BASE/bundle/Info.plist" "$APP/Contents/Info.plist"
cp "$BASE/kb-usage-menubar" "$APP/Contents/MacOS/kb-usage-menubar"
sign "$APP"

# 2. plist 설치 (__BASE__ 치환)
mkdir -p "$HOME/Library/LaunchAgents"
sed "s#__BASE__#$BASE#g" "$BASE/$LABEL.plist" > "$PLIST_DST"

# 3. (재)기동
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
# bootout 이 끝나기 전에 bootstrap 하면 "Input/output error" — 내려갈 때까지 기다린다
for _ in 1 2 3 4 5 6 7 8 9 10; do
  launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || break
  sleep 0.5
done
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
