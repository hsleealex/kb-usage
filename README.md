# kb-usage — Claude · Codex 사용 한도 맥 메뉴바 표시기

맥 메뉴바에 Claude 사용 한도(5시간 창 / 주간)와 Codex(ChatGPT 구독) 한도를
링 아이콘으로 띄운다. 클릭하면 팝오버에 % · 게이지 · 리셋 시각, **이번 주
모델별 토큰·비용**, 그리고 **세션 목록**(작업 중 / 승인 필요 / idle, 행 클릭 =
그 터미널 창으로).

```
statusline.py    Claude Code statusLine 훅. 서버가 주는 rate_limits
                 (5h·주간 used_percentage / resets_at) 를 rate_limits.json 에 저장.
                 model_usage.py 를 비차단으로 스폰한다 (45초 스로틀).
session_state.py Claude Code 상태 훅. 세션별 상태(작업 중 / 승인 필요 / idle)·도구
                 이름·todo 진행을 sessions/<id>.state.json 에 쓴다.
model_usage.py   ~/.claude 로그를 현재 5h창/주간창 구간만 잘라 모델별 토큰·$ 로
                 집계 → model_usage.json. 서버는 모델별 한도를 안 주므로 로컬 실측.
codex_usage.py   공식 `codex app-server --stdio` 에 한도·최근 스레드를 물어
                 codex_limits.json 에 쓴다. 메뉴바 앱이 --daemon 으로 띄운다.
kb-usage-menubar Swift 메뉴바 앱. 위 파일들을 2초마다 폴링해서 표시.
                 팝오버 높이는 내용에 맞춰 늘고 준다 (세션 목록은 넘치면 스크롤).
```

## 왜 메뉴바인가 (iCUE 키보드 화면이 아니라)

Corsair Vanguard 96 키보드 LCD 에 띄우려 했으나 iCUE 커스텀 위젯이
**하드웨어 센서만** 읽고 외부 데이터(fetch/파일/인라인 주입) 를 전부 막는다.
커스텀 data provider 도 못 만든다 (6개 내장 provider 고정). iframe 위젯은
XENEON EDGE 전용. → macOS + keyboard LCD 조합은 경로가 없어 메뉴바로 전환.

## 구성

| 파일 | 역할 |
|---|---|
| `menubar.swift` / `kb-usage-menubar` | 메뉴바 앱 (AppKit, 의존성 0). 빌드는 `./install.sh` (`Info.plist` 를 실행 파일에 박는다 — "Ghostty 제어" 권한 설명) |
| `bundle/Info.plist` | `KbUsage.app` 의 Info.plist 이자 단독 실행 파일에 박는 plist: 번들 id `kb-usage-menubar`(= defaults 도메인), Apple Events 권한 설명 |
| `statusline.py` | Claude Code statusLine 훅. `rate_limits` → `rate_limits.json`. `model_usage.py` 스폰 |
| `rate_limits.json` | 최신 스냅샷 (`{rate_limits, captured_at}`) |
| `model_usage.py` | 현재 5h창/주간창 구간 로그 → **모델별** 토큰·$ (`--print` / `--force`) |
| `model_usage.json` | 모델별 집계 스냅샷 (`{computed_at, last_model, weekly, five_hour}`) |
| `sessions/<id>.json` | **세션별** 컨텍스트 %·비용 스냅샷. 세션마다 자기 파일만 씀 |
| `session_state.py` | Claude Code 상태 훅 → `sessions/<id>.state.json` (상태·도구·todo·터미널 pid) |
| `codex_usage.py` | Codex 한도·최근 스레드 → `codex_limits.json` (`--daemon` / `--print`) |
| `codex_limits.json` | Codex 스냅샷 (`{ok, error, checked_at, captured_at, rate_limits, threads}`) |
| `usage_stats.py` | 별도 유틸 — `~/.claude` 로그로 **누적 토큰·비용** 집계 (`--pretty`) |
| `install.sh` / `uninstall.sh` | 메뉴바 앱 빌드 + launchd 상주 등록/해제 |

## 메뉴바 아이콘

같은 모양·굵기의 **이중 링 두 개** — 왼쪽 Claude(테라코타 #D97657), 오른쪽
Codex(시안 #5cdcff). 링마다 **바깥 = 5시간, 안쪽 = 주간**, 12시부터 시계방향으로
사용률만큼 채워진다. 라이트 메뉴바에선 같은 계열을 진하게.

- **95%+** → 그 링이 장미색(#ff5d6c)
- **80%+** → 색이 아니라 모양으로 (테라코타와 헷갈리지 않게). 변형에 따라 다름 ↓
- Claude statusLine 30분+ 미갱신 / Codex 조회 불가 → 그 서비스 링이 회색·빈 칸
- **승인 대기** 세션이 하나라도 있으면 두 링 사이 위에 호박색(#ffad4d) 점

80%+ 표현은 세 가지 변형 중 고른다 (재빌드 불필요, 앱 재시작만):

```bash
defaults write kb-usage-menubar iconVariant 1   # 1 | 2 | 3 (기본 1)
launchctl kickstart -k gui/$(id -u)/com.gaedongi.claude-usage-menubar
./kb-usage-menubar --render-icon /tmp/icons.png # 세 변형 × 다크/라이트 × 상태 비교 시트
```

| 변형 | 80%+ 단서 |
|---|---|
| 1 | **굵기 (기본)** — 80%+ 인 링이 굵어진다 |
| 2 | 외곽선 — 그 서비스 링 바깥에 얇은 테두리 (다크=흰, 라이트=검, 95%+ 장미색) |
| 3 | 글로우 — 그 서비스 색으로 은은한 번짐 |

## Codex 한도

Codex CLI 는 statusLine 훅이 없어서, 공식 **`codex app-server --stdio`** (JSON-RPC)
에 물어본다: `account/rateLimits/read`(5h·주간 %, 리셋, 요금제) + `thread/list`
(최근 스레드 제목·출처·마지막 활동). 둘 다 계정 메타데이터 조회라 **모델 토큰을
쓰지 않는다**. 계정 단위 값이라 다른 기기에서 쓴 사용량도 반영되고, 세션 로그
파일은 읽지 않는다.

- 메뉴바 앱이 `codex_usage.py --daemon` 을 자식으로 하나 띄운다. 데몬은 app-server
  하나를 붙잡고 **60초마다** 조회만 한다 (app-server 를 매번 띄우면 1초쯤 걸리고
  `~/.codex` 상태 DB·플러그인 캐시를 매번 건드려서). 앱이 죽으면 데몬도 내려간다.
- 조회 실패/데몬 멎음 → 팝오버에 `UNAVAILABLE` + `LAST OK N분 전`, 옛 % 는 흐리게.
- 리셋 시각이 지난 창은 0% (`reset since last check`).
- 실행 파일은 `~/.local/bin/codex` 우선, 없으면 PATH 의 `codex`.
- 스레드 상태(`status`)는 app-server 가 **자기가 로드한 스레드**에만 준다. 다른
  프로세스(ChatGPT 앱·CLI)가 돌리는 스레드는 늘 `notLoaded` 라 상태를 지어내지 않고
  "활동 N분 전"만 보인다.

- **소진 ETA** — Claude 쪽(statusline.py)과 같은 방식: 10분+ 간격 baseline 대비 %상승
  기울기로 `eta_at` 을 계산해 5H / WEEKLY 막대 아래 `est. … to limit`.
- **BY MODEL / WEEK** — 서버가 모델별 사용량을 안 줘서 **이 Mac 의 rollout 을 로컬 집계**:
  `turn_context`(payload.model)로 현재 모델을 따라가고 `token_count` 의
  `last_token_usage.total_tokens`(input 캐시 포함 + output reasoning 포함 — Claude 쪽
  model_usage.py 와 같은 정의)를 더한다. 같은 턴이 겹쳐 찍힌 token_count 는 한 번만.
  기간은 Codex 주간 한도 창(`resets_at − 창 길이` ~ 지금). 상위 3 + 기타(unknown 포함).
  Claude 기록을 변환해 들여온 세션(`external_agent_session_imports.json`)은 뺀다.
  파일별 (mtime, size, 읽은 offset, 5분 단위 모델별 토큰) 캐시
  (`codex_models_cache.json`, 상대경로·숫자만)로 새로 붙은 줄만 증분으로 읽는다.
  각 줄은 type·model·토큰 숫자만 꺼내고 버린다 — 대화·도구 입출력은 남기지 않는다.
  **이 Mac 기준**: 다른 기기 사용량과 `--ephemeral` 호출은 rollout 이 없어 안 잡힌다.
- **지금 떠 있는 CLI** — 데몬이 10초마다 codex CLI 프로세스(app-server / exec / ChatGPT 앱
  자식 제외)가 연 rollout 파일명에서 thread id 를 뽑아 `live` 에 쓴다 (내용은 안 읽음).

```bash
python3 codex_usage.py --print    # 한 번 조회 → codex plus: 5h 24%  7d 4% · 12 threads
```

## 세션 목록 (상태 훅)

`session_state.py` 를 Claude Code 훅으로 걸면 세션마다 상태가 보인다.

| 상태 | 훅 이벤트 | 표시 |
|---|---|---|
| 승인 필요 | `Notification` (permission_prompt / elicitation_dialog / agent_needs_input) | 호박색 삼각형 깜빡임, 맨 위 |
| 작업 중 | `UserPromptSubmit` / `PreToolUse` / `PostToolUse` | 에이전트 색 점 숨쉬기 |
| idle | `SessionStart` / `Stop` | 흐린 빈 원, Stop 뒤면 "완료 후 N분" |
| (삭제) | `SessionEnd` | 그 세션 파일 두 개 삭제 |

행마다 상태 경과시간, 진행 상황 한 줄(현재/직전 도구 + 파일 basename, TodoWrite 가
있으면 `✓ 완료/전체 · 진행 중 항목`), 남은 컨텍스트. **행을 클릭하면 그 세션의
터미널 창**이 앞으로 온다 — 훅이 세션 시작 때 부모 프로세스를 거슬러 올라가 처음
만나는 `.app` 프로세스(Ghostty 등) pid 를 기록한다. 창마다 프로세스가 따로인
터미널이면 그 창이, 한 프로세스에 창이 여럿이면 앱까지만 온다.

**행은 지금 살아있는 프로세스가 받치고, 터미널 창이 있을 때만 보인다.**
- Claude: Claude Code 자체 레지스트리 `~/.claude/sessions/<pid>.json`(pid·sessionId·
  procStart·name — 대화 내용 없음)로 세션의 claude pid 를 찾고, pid + 시작 시각이 맞아야
  살아있음 (pid 재사용 오탐 방지). 조상에 터미널 앱(Ghostty 등)이 없으면 — 예: 재부팅
  복원이 tmux 헤드리스로 띄운 세션 — **창 없음으로 숨긴다**. 레지스트리에 없으면 상태 훅의
  claude pid, 그것도 없으면 statusLine 90초 이내 폴백(닫은 세션이 최대 90초 남을 수 있음).
- 행 클릭: 한 Ghostty 프로세스가 창·탭을 여럿 품으므로 프로세스만 올리면 엉뚱한 창이
  온다. 그래서 Ghostty AppleScript(sdef: terminal id/name, `focus`)를 **그 pid 에 직접**
  Apple Event 로 보내 (`tell application "Ghostty"` 는 프로세스가 둘 이상이면 하나에만 닿음)
  제목에서 상태 글리프를 뗀 값이 세션 이름(자동 제목)과 **정확히 하나** 맞는 터미널을
  focus 한 뒤 그 프로세스를 앞으로. 안 맞거나 여럿이면 프로세스 단위로 폴백.
  처음 한 번 macOS 가 **"kb-usage" 가 "Ghostty" 를 제어하도록 허용할지** 묻는다
  (시스템 설정 → 개인정보 보호 및 보안 → 자동화). 거부하면 프로세스 단위로만 간다.
  권한을 물으려면 앱이 **번들**이어야 해서 메뉴바 앱은 `KbUsage.app` 으로 띄운다 (install.sh 가
  빌드·복사·ad-hoc 서명 — 식별자 `kb-usage-menubar`, 요구사항도 식별자 기준이라 재빌드해도
  같은 앱). 번들 없는 실행 파일은 macOS 가 팝업을 못 띄우고 바로 거부(-1743)하거나 권한을
  경로로 기록해 설정 화면에 안 나타난다. 권한 상태는 `menubar.log` 의
  `ae-permission … status=` (0 허용, -1743 거부, -1744 미결정 → 물음)로 보인다.
  클릭·포커스 단계는 `menubar.log` 에 key 앞 8자·pid·결과만 남는다.
- Codex CLI(`source` = `cli`, codex-tui): 그 스레드의 rollout 을 연 codex CLI 프로세스가
  지금 떠 있을 때만 (`live`). 클릭 = 그 프로세스의 터미널 창, 모르면 Ghostty 앱.
- Codex Work: ChatGPT 앱(`com.openai.codex`)이 떠 있을 때만 한 줄 — 앱 스레드
  (`vscode` = Codex Desktop / Work)를 묶는다. 마지막 활동 · 최근 30분 스레드 수,
  클릭 = ChatGPT 앱.

정렬은 **안정적**이다: 승인 필요 행이 맨 위(승인 대기 시작 순), 나머지는 에이전트
종류(돌쇠 → 개똥이 → 기타 Claude → Codex CLI → Codex Work) → 세션 시작 시각.
갱신 시각으로는 정렬하지 않는다. 목록은 세션 key 로 diff 해서 제자리 갱신하고
(행 재사용, 바뀐 행만 다시 그림, 같은 입력이면 아무것도 안 함), 깜빡임은 승인 필요
행에만 붙는 레이어 애니메이션이라 새로고침에 재시작되지 않는다.

훅은 모든 세션의 모든 도구 호출에 붙으므로 **아무것도 출력하지 않고, 항상 exit 0,
~35ms**. 기록하는 건 상태·시각·도구 이름·파일 basename·todo 개수와 진행 항목
제목(40자)·pid 뿐이다. 프롬프트·명령어·도구 입출력·대화 본문은 읽지도 쓰지도
않는다. statusLine 이 쓰는 `<id>.json` 과 파일을 나눈 건 statusLine 이 3초마다
자기 파일을 통째로 다시 써서 섞으면 지워지기 때문.

`~/.claude/settings.json` 의 `hooks` 에 이벤트마다 **별도 항목**으로 추가 (기존
훅은 그대로 둔다):

```json
"PreToolUse": [
  { "hooks": [ { "type": "command",
                 "command": "/usr/bin/python3 ~/developer/kb-usage/session_state.py",
                 "timeout": 5 } ] }
]
```

같은 항목을 `SessionStart`, `UserPromptSubmit`, `PostToolUse`, `Stop`, `SessionEnd`
에도, `Notification` 에는 `"matcher": "permission_prompt|elicitation_dialog|agent_needs_input"`
를 붙여서 추가한다. 훅이 없으면 목록은 뜨지만 상태 칸이 비고 빈 원으로만 보인다.

## 승인 알림 팝업 연동

승인·질문 대기 알림 팝업(별도 Notification 훅이 alerter 로 띄우는 것, 그룹 `cc-<session_id>`)과 엮는다.

- **기본: kb-usage 가 커버하는 세션은 팝업 없이 메뉴바로.** 팝업 훅이 "kb-usage 앱이 떠 있고
  이 세션에 상태 훅 파일(`sessions/<id>.state.json`)이 있고 그 claude pid 가 살아있음"이면
  아무 알림도 안 낸다. 대신 kb-usage 가 승인 대기 **진입 순간 소리 1회**(attentionSound, 기본
  Glass)와 메뉴바 점 펄스로 알린다. 앱 시작 때 이미 대기 중인 세션이나 폴링 갱신으로는 소리를
  안 내고, 여럿이 한꺼번에 들어와도 2초에 한 번.
- **커버 안 되는 세션은 팝업이 안전망**: 상태 훅이 적용되기 전에 열린 세션(훅 설정은 새로 연
  세션부터 먹는다 — 그 세션을 새로 열거나 `/hooks` 로 반영하면 커버된다), kb-usage 앱이 안 떠
  있을 때. 항상 팝업을 원하면 `defaults write kb-usage-menubar legacyPopup -bool YES`
  (또는 환경변수 `KB_LEGACY_POPUP=1`).
- **팝업 클릭 → 정확한 창**: 팝업 쪽이 `kb-usage-menubar --focus <session_id>` 를 부르면
  실행 중인 메뉴바 앱에 분산 알림으로 요청이 가고, 앱이 위 "행 클릭"과 같은 방식으로 그
  세션의 Ghostty 창(탭)까지 골라 올린다 (ack 를 3초 기다림, 앱이 없거나 실패하면 exit 1 →
  팝업 쪽이 자기 방식으로 폴백). **Ghostty 제어 권한이 이 앱 한 곳에만 필요**하도록 실제
  제어는 상주 앱이 한다.
- **처리하면 팝업 자동 해제**: (폴백으로 팝업이 떴을 때) `session_state.py` 가 attention →
  working/idle(또는 세션 종료)로 풀리는 순간에만 `alerter --remove cc-<id>`
  (·`terminal-notifier -remove`)를 분리된 프로세스로 띄운다. 평소 이벤트는 비교 한 번뿐.
- **메뉴바**: 승인 대기 세션이 있으면 두 링 사이 위 호박색 점이 은은히 펄스 (레이어
  애니메이션). 팝오버를 열면 그때의 대기들은 본 것으로 → 정지, 새 대기가 오면 다시.
  "동작 줄이기"가 켜져 있으면 펄스 없이 정적 점.
- **소리 옵션** — 진입 소리 1회 외에는 기본 꺼짐이고, **반복 알림(attentionRepeatMinutes)은 비권장**:

```bash
defaults write kb-usage-menubar attentionRepeatMinutes 5   # 승인 대기가 5분 넘게 이어질 때마다 소리 + 펄스 재개 (0=끔)
defaults write kb-usage-menubar attentionSound Glass      # 진입 소리 ("" = 무음)
defaults write kb-usage-menubar doneNotify -bool YES       # 오래 걸린 작업이 끝났는데 그 창을 안 보고 있으면 1회
defaults write kb-usage-menubar doneNotifyMinMinutes 3
defaults write kb-usage-menubar doneSound Tink
```

## 데이터 갱신

| 단계 | 주기 |
|---|---|
| statusLine → `rate_limits.json` | 3초 (`~/.claude/settings.json` 의 `refreshInterval`) |
| statusLine → `model_usage.py` 스폰 | `model_usage.json` 이 45초+ 묵었을 때만 (비차단) |
| `model_usage.py` 전체 스캔 | ~0.6s (160MB 로그). 그래서 백그라운드 |
| 메뉴바 폴링 | 2초 (팝오버 닫혀 있으면 아이콘만) |
| 팝오버 열려있을 때 | 1초 (리셋 카운트다운) |
| `codex_usage.py --daemon` → `codex_limits.json` | 60초 (실패가 이어지면 최대 10분까지 늘림) |
| `session_state.py` 훅 | 이벤트마다 (~35ms) |

**모델별 사용량은 로컬 실측**이다. Anthropic `rate_limits` 는 계정 합산 5h창/
주간창만 준다 — 소넷·오퍼스·페이블이 같은 풀을 깎는다. 그래서 "모델별로 얼마"
는 `~/.claude` 로그의 토큰을 `model_usage.py` 가 창 구간만 잘라 직접 합산한다.
단가표는 `usage_stats.py` 의 `PRICING`.

## statusLine payload 에서 실제로 오는 것 (2026-09-09 조사, v2.1.267)

```
rate_limits     five_hour / seven_day 뿐. **Opus 전용 주간 한도 키는 없다.**
                Max 플랜에서 오퍼스 세션으로 확인 — 소넷 payload 와 키 완전 동일.
context_window  used_percentage, context_window_size, current_usage  ← 세션별
cost            total_cost_usd, total_lines_added/removed            ← 세션별
prompt_cache    hit_ratio, warm, ttl, expires_at, miss_causes        ← 세션별
session_id / session_name / model / workspace / effort / thinking / fast_mode
```

`context_window`·`cost`·`prompt_cache` 는 **세션별** 값이라 여러 세션이 한 파일을
공유하면 서로 덮어쓴다. 그래서 `sessions/<session_id>.json` 으로 나눠 쓰고,
메뉴바가 `updated_at` 90초 이내이거나 상태 훅이 남긴 claude pid 가 살아있는 것만 세션
목록에 올린다 (statusLine 이 안 도는 헤드리스 `claude -p` 는 자연히 빠진다). `agent` 는 output style 이름 (default 면 null).

## 팝오버 섹션

**CLAUDE** 와 **CODEX** 는 같은 컴포넌트로 그린다: 서비스 이름 헤더(서비스 색, 우측
플랜/경고) → 5H / WEEKLY 두 줄(같은 라벨·24pt 숫자·6px 막대·리셋 문구) → UPDATED 줄.
숫자는 흰색, 80%+ 서비스 색, 95%+ 장미색.

- **CLAUDE** — Anthropic `rate_limits`. 막대 아래 **소진 ETA**: `statusline.py` 가 각
  창의 `rate_ref`(10분+ 간격 baseline) 대비 %상승 기울기로 `eta_at` 을 계산 → 리셋보다
  이르면 서비스 색으로 경고. 페이스가 느리면(10분에 <0.5%p) 줄 안 뜸. 하위 블록
  **BY MODEL / WEEK** — 이번 주 토큰 비중 + 막대 (종량 과금 모델만 `$N`).
- **CODEX** — 위 "Codex 한도".
- **SESSIONS** — 위 "세션 목록". 최대 330pt, 넘치면 스크롤.

`rate_limits` 는 Claude 구독자에게 첫 API 응답 뒤부터 내려온다. Claude Code
세션이 떠 있어야 statusLine 이 돌아 값이 신선하게 유지된다.

## 설치

```bash
cd ~/developer/kb-usage
./install.sh          # 빌드 + launchd 상주 (로그인 시 자동 실행)
```

`~/.claude/settings.json` 에 statusLine 설정이 있어야 데이터가 채워진다:

```json
"statusLine": {
  "type": "command",
  "command": "/usr/bin/python3 ~/developer/kb-usage/statusline.py",
  "refreshInterval": 3
}
```

## 제거

```bash
./uninstall.sh
# iCUE 에 남은 "Claude Usage" 위젯은 iCUE 화면유형에서 직접 삭제
```
