# kb-usage — Claude 사용 한도 맥 메뉴바 표시기

맥 메뉴바에 Claude 사용 한도(5시간 창 / 주간)를 이중 링 아이콘으로 띄운다.
클릭하면 팝오버에 % · 게이지 · 리셋 시각, 그리고 **이번 주 모델별 토큰·비용**
(소넷 / 오퍼스 / 페이블 …) 상세.

```
statusline.py    Claude Code statusLine 훅. 서버가 주는 rate_limits
                 (5h·주간 used_percentage / resets_at) 를 rate_limits.json 에 저장.
                 model_usage.py 를 비차단으로 스폰한다 (45초 스로틀).
model_usage.py   ~/.claude 로그를 현재 5h창/주간창 구간만 잘라 모델별 토큰·$ 로
                 집계 → model_usage.json. 서버는 모델별 한도를 안 주므로 로컬 실측.
kb-usage-menubar Swift 메뉴바 앱. rate_limits.json + model_usage.json 을 2초마다
                 폴링해서 표시. 팝오버 높이는 모델 줄 수에 따라 늘고 준다.
```

## 왜 메뉴바인가 (iCUE 키보드 화면이 아니라)

Corsair Vanguard 96 키보드 LCD 에 띄우려 했으나 iCUE 커스텀 위젯이
**하드웨어 센서만** 읽고 외부 데이터(fetch/파일/인라인 주입) 를 전부 막는다.
커스텀 data provider 도 못 만든다 (6개 내장 provider 고정). iframe 위젯은
XENEON EDGE 전용. → macOS + keyboard LCD 조합은 경로가 없어 메뉴바로 전환.

## 구성

| 파일 | 역할 |
|---|---|
| `menubar.swift` / `kb-usage-menubar` | 메뉴바 앱 (AppKit, 의존성 0). `swiftc -O menubar.swift -o kb-usage-menubar` |
| `statusline.py` | Claude Code statusLine 훅. `rate_limits` → `rate_limits.json`. `model_usage.py` 스폰 |
| `rate_limits.json` | 최신 스냅샷 (`{rate_limits, captured_at}`) |
| `model_usage.py` | 현재 5h창/주간창 구간 로그 → **모델별** 토큰·$ (`--print` / `--force`) |
| `model_usage.json` | 모델별 집계 스냅샷 (`{computed_at, last_model, weekly, five_hour}`) |
| `sessions/<id>.json` | **세션별** 컨텍스트 %·비용 스냅샷. 세션마다 자기 파일만 씀 |
| `usage_stats.py` | 별도 유틸 — `~/.claude` 로그로 **누적 토큰·비용** 집계 (`--pretty`) |
| `install.sh` / `uninstall.sh` | 메뉴바 앱 빌드 + launchd 상주 등록/해제 |

## 메뉴바 아이콘

- **이중 링**: 바깥 = 주간, 안쪽 = 5시간. 12시부터 시계방향으로 사용률만큼 채워짐
- **색**: 기본 → 80%↑ 주황 → 95%↑ 빨강
- 5시간 창 idle(5시간 넘게 미사용) → 안쪽 링 대신 가운데 점
- statusLine 30분+ 미갱신 → 전체 주황 (stale)

## 데이터 갱신

| 단계 | 주기 |
|---|---|
| statusLine → `rate_limits.json` | 3초 (`~/.claude/settings.json` 의 `refreshInterval`) |
| statusLine → `model_usage.py` 스폰 | `model_usage.json` 이 45초+ 묵었을 때만 (비차단) |
| `model_usage.py` 전체 스캔 | ~0.6s (160MB 로그). 그래서 백그라운드 |
| 메뉴바 폴링 | 2초 |
| 팝오버 열려있을 때 | 1초 (리셋 카운트다운) |

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
메뉴바가 `updated_at` 90초 이내인 것만 `started_at` 순 최대 3개 표시(넘치면
`+N more running`).

## 팝오버 섹션

- **5H LIMIT / WEEKLY** — Anthropic `rate_limits` %·게이지·리셋. 그 아래 **소진 ETA**:
  `statusline.py` 가 각 창의 `rate_ref`(10분+ 간격 baseline) 대비 %상승 기울기로
  `eta_at` 을 계산 → 리셋보다 이르면 "이 페이스면 N분 뒤 소진" 경고. 페이스가
  느리면(10분에 <0.5%p) 줄 안 뜸.
- **SESSIONS** — 세션별 이름·모델, **남은 컨텍스트 토큰**(`context_size × 잔여%`),
  컨텍스트 게이지(85%+ 주황 `compact 임박`), 그 아래 `+추가 −삭제 · 세션시간`.
- **BY MODEL / WEEK** — 이번 주 토큰 **비중(share %)** + 막대. 종량 과금(페이블 등)
  모델만 실제 청구액 `$N` 표시.

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
  "command": "/usr/bin/python3 /Users/hsleealex/developer/kb-usage/statusline.py",
  "refreshInterval": 3
}
```

## 제거

```bash
./uninstall.sh
# iCUE 에 남은 "Claude Usage" 위젯은 iCUE 화면유형에서 직접 삭제
```
