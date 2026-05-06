# Runbook — Korean Stock Mock Portfolio

**스케줄 에이전트가 매 차수마다 따르는 절차서.** 호출 프롬프트는 이 파일을 읽고 그대로 실행한다. 자기 자신은 이전 차수의 컨텍스트를 모른다는 가정 하에 모든 정보는 디스크에서 로드한다.

---

## 0. 입력 변수

호출 프롬프트가 다음을 전달:
- `cycle`: 1, 2, 또는 3 (오전/점심/마감)
- `today`: YYYY-MM-DD (KST)
- `now_kst`: HH:MM (KST)

## 0.5. Git 동기화 (먼저)

클라우드 에이전트는 격리된 워킹디렉토리에서 시작한다. 매 실행은 git에서 시작하고 git으로 끝나야 한다.

```
git pull --rebase origin main   # 다른 차수의 최신 변경분 흡수
```

pull 실패 시: 즉시 중단하고 사용자에게 상황 보고 (충돌은 자동 해결하지 말 것).

## 1. 휴장일 / 주말 체크

```
1. holidays.json 로드, today가 closures 배열에 있으면 → 즉시 종료, decisions.md에 한 줄 기록 ("YYYY-MM-DD 휴장 — 점검 스킵")
2. today의 요일이 토/일이면 → 즉시 종료 (cron이 평일만 fire하지만 안전장치)
```

## 2. 상태 로드

다음 파일을 Read 도구로 모두 읽는다:
- `portfolio.json` — 현재 보유, 현금, 누적 수수료
- `watchlist.json` — 모니터링 종목 + 벤치마크
- `decisions.md` — **마지막 5개 항목만** 참고 (오버트레이딩 방지 컨텍스트)
- `analysis.md` — 시장관 노트
- `trade_log.md` — 마지막 3개 거래만 참고

## 3. 시세 조회 (전 종목 + 벤치마크)

watchlist.tickers 전 종목 + benchmarks의 코오롱티슈진(950160) + KODEX 200(069500)에 대해 폴백 체인으로 시세 수집.

**폴백 체인 (종목당 순서대로 시도)** — robots.txt 호환 + 클라우드 검증 소스만:
1. **Bash + curl + 한경 추출** ★★ PRIMARY (검증) — 클라우드 WebFetch가 자주 403이라 curl이 더 신뢰. 아래 §3.1 레시피 참고.
2. 실패 시 `google_url`로 WebFetch
3. 실패 시 `hankyung_url`로 WebFetch (curl 실패 시 추가 시도)
4. 실패 시 `investing_url` (있는 경우)
5. 실패 시 **WebSearch 폴백** (§3.5) — 마지막 수단, 보수적 처리
6. 모두 실패 → 해당 종목 결측 처리, decisions.md에 기록, 그 차수 매매 결정 스킵

## 3.1. Bash + curl 한경 추출 레시피 (PRIMARY)

클라우드 환경의 WebFetch는 종종 HTTP 403. **Bash + curl + 브라우저 UA**가 더 안정적임이 검증됨 (2026-05-06 14:30 KST 로컬 검증, 6종목 모두 정상 추출).

**한 종목 추출 함수**:
```bash
extract_hk() {
  local code=$1
  local html=$(curl -sL -H "User-Agent: Mozilla/5.0 (Windows NT 10.0)" "https://markets.hankyung.com/stock/$code")
  local oneline=$(echo "$html" | tr '\n' ' ')
  local price=$(echo "$oneline" | grep -oE 'stock-data txt-num[^"]*"[^<]*<p class="price">[[:space:]]*[0-9,]+' | head -1 | grep -oE '[0-9,]+$' | tr -d ',')
  local change=$(echo "$oneline" | grep -oE 'class="rate">[+-]?[0-9.]+%' | head -1 | grep -oE '[+-]?[0-9.]+')
  echo "{\"code\":\"$code\",\"price\":$price,\"change_pct\":$change,\"source\":\"hankyung_curl\"}"
}
```

**전 종목 일괄 호출 (병렬)**:
```bash
for code in 005930 000660 042700 122630 233740 247540 196170 028300 035720 035420 229200 069500 950160; do
  extract_hk "$code" &
done
wait
```

**검증 (2026-05-06 14:30 KST 로컬)**:
| 종목 | 추출가 | 변동률 |
|---|---|---|
| 005930 삼전 | ₩264,000 | +13.55% |
| 000660 하이닉스 | ₩1,596,000 | +10.30% |
| 196170 알테오젠 | ₩363,500 | -2.55% |
| 122630 KODEX 레버리지 | ₩146,970 | +15.01% |
| 069500 KODEX 200 | ₩113,180 | +7.49% |
| 950160 코오롱티슈진 | ₩102,400 | -2.29% |

**주의**: 한경 데이터는 공식적으로 **20분 지연** 명시. source 필드에 `"hankyung_curl"`로 기록. day_high/day_low/prev_close는 별도 grep 패턴 필요 시 추가 — 우선순위 낮음, 가격 + 변동률만 있으면 의사결정 충분.

**⚠️ 사용 금지 소스 (robots.txt에서 ClaudeBot 명시 차단)**:
- `*.yahoo.com` (finance.yahoo.com, query1.finance.yahoo.com 모두)
- `finance.naver.com`, `m.stock.naver.com`, `api.stock.naver.com` (WebFetch 자체 차단 + 약관)

**병렬 호출 권장**: 12종목+벤치마크 2개 = 14개 WebFetch를 한 메시지에 병렬로 보낸다.

**WebFetch 프롬프트 표준 (Google/Hankyung HTML)**:
```
Extract: current price (KRW integer), change (KRW), change_pct (number), day_high, day_low, previous_close, timestamp. Return JSON only.
```

**레버리지 ETF 추가 검증**: 122630 (KODEX 레버리지) / 233740 (KODEX 코스닥150 레버리지)는 codes 변경 가능성 낮으나, 첫 fetch에서 prev_close 대비 일중 변동이 KOSPI 200 / KOSDAQ 150 변동의 약 2배인지 확인 (sanity check). 어긋나면 결측 처리.

## 3.5. WebSearch 폴백 요령

WebFetch 3개 모두 실패한 종목에 한해 WebSearch로 마지막 시도. **클라우드 환경 WebFetch가 종종 차단됨 (특히 finance.yahoo.com, finance.naver.com)이라 이 폴백이 자주 활성화될 가능성 높다.**

### 쿼리 템플릿 (효과 검증된 패턴, 우선순위 순)

1. **한글 풀쿼리**: `"{종목명} {코드} 현재가 2026년 {M}월 {D}일"`
   - 예: `삼성전자 005930 현재가 2026년 5월 6일` → MSN/Investing/Daum/Hankyung 결과 다수
2. **영문 백업**: `"{영문 종목명} {코드}.KS stock price today"`
   - 예: `Samsung Electronics 005930.KS stock price today` (KOSPI는 .KS, KOSDAQ는 .KQ)
3. **단순 패턴**: `"{코드} 주가"` — 빠른 조회용 fallback

### 결과 파싱 요령

WebSearch 결과는 자연어 답변 + 링크 리스트 형태. 다음 순서로 가격 추출:

1. **답변 텍스트에서 정규식 매칭** (최우선):
   - 패턴: `₩[\d,]+` 또는 `[\d,]+원` 또는 `KRW [\d,.]+`
   - 예: "현재가는 220,500원이며" → 220500
2. **여러 소스 교차검증**:
   - 답변에 2개 이상 가격이 언급되면 (예: "MSN 220,500원, 한경 225,500원") → 평균 또는 더 최신 timestamp 가격 채택
   - 차이가 ±5% 이상이면 → 의심, 결측 처리
3. **링크 텍스트 활용**:
   - 검색 결과 link title에 가격 포함되는 경우도 흔함
   - 예: "005930 220,500.00 -5,500.00 -2.43% : 삼성전자" → price=220500, change=-5500, change_pct=-2.43

### 안전장치 (sanity check)

WebSearch로 얻은 가격은 다음 중 **하나라도 위반하면 결측 처리**:
- `latest_snapshot.json`에 직전 가격이 있는 경우, 그 가격 대비 ±20% 초과 (한국 시장 일중 상한가/하한가는 ±30%이지만 보수적으로 ±20%로 설정)
- 가격이 음수, 0, 1억 초과
- 텍스트에서 추출한 숫자가 단위(원/만원/억원) 모호 → "원" 단위가 명시된 경우만 채택

### 메타데이터 기록

WebSearch로 채운 가격은 `latest_snapshot.json`의 `prices.{code}` 항목에:
```json
{"price": 220500, "change_pct": -2.43, "fetched_at": "...", "source": "websearch", "confidence": "low"}
```

`source: "websearch"` 종목은 의사결정 시 **보수적 처리**:
- 신규 매수 1단위만 허용 (분할 강도 절반)
- 손절/익절은 정상 트리거 (가격이 실제 다를 수 있어도 안전 방향)

### 예시 (cycle 2가 005930 시세 폴백 시)

```
1. WebFetch google.com/finance/quote/005930:KRX → fail (cloud blocked)
2. WebFetch markets.hankyung.com/stock/005930 → fail
3. (no investing_url for some) → skip
4. WebSearch "삼성전자 005930 현재가 2026년 5월 6일"
   → 결과 텍스트에서 "260,500원" 추출
   → 직전 snapshot 260,500과 일치 → confidence high → 채택
5. record source="websearch", proceed with decision
```

수집 결과를 다음 구조로 메모리 정리:
```json
{
  "code": "005930",
  "price": 260500,
  "change_pct": 12.04,
  "day_high": 261500,
  "day_low": 251000,
  "prev_close": 232500,
  "source": "google",
  "fetched_at": "2026-05-06T09:37:12+09:00"
}
```

## 4. 마크투마켓 + PnL

각 보유 종목:
```
position_value = shares × current_price
unrealized_pnl = position_value − (shares × avg_cost)
unrealized_pnl_pct = unrealized_pnl / (shares × avg_cost) × 100
```

포트 합계:
```
total_equity = cash + Σ position_value
total_pnl = total_equity − starting_capital (100,000,000) − fees_paid_total
total_pnl_pct = total_pnl / starting_capital × 100
```

## 5. 의사결정 룰 — 공격형 (AGGRESSIVE)

각 종목에 대해 우선순위대로 평가, **첫 매치되는 룰만 실행**:

| 우선순위 | 조건 | 행동 |
|---|---|---|
| 1 (강제) | 평단 대비 -15% 이하 | 전량 매도 (손절) |
| 2 (강제) | 평단 대비 +30% 이상 | 1/4 매도 (익절, 러너 유지) |
| 3 (제한) | 단일 종목 비중 > 30% | 30% 초과분 매도 |
| 4 (강제 매도) | watchlist에서 `bucket == "legacy_to_exit"` 또는 `target_weight_pct == 0` | 전량 매도 (포지션 정리) |
| 5 (금지) | 일중 +10% 이상 급등 | 신규/추가매수 차단 (단 +10% 미만은 모멘텀 추격 허용) |
| 6 (매수, 모멘텀) | 보유 < 목표×0.5 AND 일중 +5%~+10% | 매수 1단위 (목표 × 50%) — 모멘텀 추종 |
| 7 (매수, 눌림) | 보유 < 목표×0.5 AND 일중 -1.5% 이하 | 매수 1단위 (목표 × 50%) — 분할 진입 |
| 8 (매수, 횡보) | 보유 < 목표×0.5 AND 일중 -1.5%~+5% | 매수 1단위 (목표 × 50%) — 빠른 진입 |
| 9 (보유) | 위 조건 모두 미해당 | HOLD |

**전역 가드 (공격형)**:
- 차수당 최대 신규 거래 **4건** (적극적 배분)
- 현금 플로어 **0%** — 풀 익스포저 허용 (단 정수주 매수로 자연 잔액 발생)
- 단일 매수당 목표비중의 **50%** (분할 2단계로 빠른 진입)
- WebFetch 결측 종목 → 그 차수 결정 스킵 (변경 없음)
- **레버리지 ETF (122630, 233740) 주의**: 일일 변동 2배 추종, 횡보장 decay 발생. 보유 중이면 +20% 이상 시 즉시 익절 1/3 (룰 2 우선)

## 6. 모의 체결 + 수수료 계산

매수:
```
buy_amount = target_krw  (룰 5/6에서 계산된 금액)
shares_to_buy = floor(buy_amount / current_price)  ← 정수주만
notional = shares_to_buy × current_price
buy_commission = notional × 0.00015
total_cost = notional + buy_commission

cash -= total_cost
fees_paid_total += buy_commission
position[code].shares += shares_to_buy
position[code].avg_cost = ((old_shares × old_avg) + notional) / new_shares  ← 평단 재계산
```

매도:
```
notional = shares_to_sell × current_price
sell_commission = notional × 0.00015
sell_tax = notional × 0.0018
proceeds = notional − sell_commission − sell_tax

cash += proceeds
fees_paid_total += sell_commission + sell_tax
realized_pnl_krw += proceeds − (shares_to_sell × avg_cost)
position[code].shares -= shares_to_sell
(shares == 0이면 position 삭제)
```

## 7. 파일 갱신

체결이 발생한 경우만:
1. `portfolio.json` 갱신 (Write 또는 Edit)
2. `trade_log.md`에 append (각 체결마다 한 블록):
   ```
   ## 2026-05-06 09:37 KST | BUY | 005930 삼성전자
   - 수량: 30주 @ ₩260,500
   - 체결금액: ₩7,815,000
   - 수수료: ₩1,172 (커미션)
   - 사유: 신규 진입 (분할 1차, 목표비중 8% 중 25%)
   - 사후 보유: 30주, 평단 ₩260,500
   - 포트 현금: ₩92,183,828
   ```

체결 여부 무관 매번:
3. `decisions.md`에 append:
   ```
   ## 2026-05-06 09:37 KST [Cycle 1]
   
   ### 시세 스냅샷
   | 종목 | 현재가 | 일중 % | 출처 |
   |---|---|---|---|
   | KODEX 200 (069500) | ₩45,200 | +0.4% | google |
   | 삼성전자 (005930) | ₩260,500 | +12.0% | google |
   | ... |
   
   ### 포트폴리오
   - 총 평가액: ₩100,012,000 (+0.012%)
   - 현금: ₩100,000,000
   - 보유 종목 수: 0
   
   ### 결정
   - 005930: 신규 매수 (₩2,000,000 분할 1차) — 목표 8% 중 25%
   - 069500: 신규 매수 (₩6,250,000 분할 1차) — 목표 25% 중 25%
   - 그 외: 미진입 또는 보유
   
   ### 벤치마크
   - KODEX 200: ₩45,200 (시작 시점 대비 +X%)
   - 코오롱티슈진: ₩104,900 (시작 시점 대비 +X%)
   
   ### 사유
   (1-3 문장으로 이번 차수 핵심 판단)
   ```

4-pre. `history.jsonl` 한 줄 append (시계열 차트용):
   ```
   {"as_of": "ISO8601", "cycle": N, "my_value_krw": <total_equity>, "kospi200_price": <price>, "kolon_price": <price>}
   ```
   - 한 cycle = 한 줄. 절대 기존 줄 수정 금지 (append-only).
   - 069500 또는 950160 시세 결측 시: 해당 필드는 직전 값 그대로 (또는 null). my_value_krw는 항상 기록.

5. `latest_snapshot.json` 덮어쓰기 — 대시보드용:
   ```json
   {
     "as_of": "2026-05-06T09:37:00+09:00",
     "cycle": 1,
     "portfolio": {
       "cash_krw": 100000000,
       "positions_value_krw": 0,
       "total_equity_krw": 100000000,
       "total_pnl_krw": 0,
       "total_pnl_pct": 0,
       "fees_paid_total_krw": 0,
       "realized_pnl_krw": 0
     },
     "positions": [
       {"code": "005930", "name": "삼성전자", "shares": 30, "avg_cost": 260500, "last_price": 260500, "unrealized_pnl_krw": 0, "unrealized_pnl_pct": 0, "weight_pct": 7.8}
     ],
     "prices": {
       "069500": {"price": 45200, "change_pct": 0.4, "fetched_at": "..."},
       "005930": {"price": 260500, "change_pct": 12.04, "fetched_at": "..."}
     },
     "benchmarks": {
       "kospi200_start_price": 45200,
       "kospi200_current_price": 45200,
       "kospi200_return_pct": 0,
       "kolon_tissuegene_start_price": 104900,
       "kolon_tissuegene_current_price": 104900,
       "kolon_tissuegene_return_pct": 0,
       "user_kolon_position_value_krw": 554921000,
       "my_portfolio_return_pct": 0
     }
   }
   ```
   - 시작 가격(`*_start_price`)은 첫 실행에서 한 번 설정한 뒤 덮어쓰지 말 것 (덮어쓰지 않도록 기존 값 우선 사용)

## 8. 마지막 차수(Cycle 3, 15:13)에만: 일일 요약

decisions.md 끝에 추가 블록:
```
### 📅 일일 요약 (2026-05-06)
- 총 평가액: ₩100,XXX,XXX (+/-X.XX%)
- 일중 변동: +/-X.XX% (오늘 누적)
- 신규 거래: N건 (매수 N, 매도 N)
- 누적 수수료: ₩X,XXX
- vs KOSPI200: +/-X.XX%p
- vs 코오롱티슈진: +/-X.XX%p
- 최고 기여 종목: XXX (+X.X%)
- 최악 기여 종목: XXX (-X.X%)
- 내일 관전포인트: (1-2 문장)
```

그리고 사용자에게 채팅으로 이 요약 블록을 전송 (cycle == 3일 때만, 그리고 사용자 알림 채널이 있는 경우에만).

## 9. 오류 처리 원칙

- WebFetch 일부 실패 → 폴백 체인 다음 단계 (1→2→3→**WebSearch 4**) 시도. 4단계까지 실패한 종목만 결측 처리.
- 모든 종목 데이터 수집 실패 → portfolio.json 변경 금지, decisions.md에 "데이터 수집 전체 실패" 기록 후 종료
- Write 실패: 같은 파일 한 번 더 시도, 또 실패하면 사용자에게 알림 (cycle 무관)
- 절대 추측해서 거래하지 말 것 — 데이터 없으면 보유
- WebSearch로 채운 가격(`source: "websearch"`)은 §3.5에 따라 보수적 처리

## 10. 실행 순서 요약

```
0. git pull --rebase origin main
1. 휴장/주말 체크
2. portfolio.json + watchlist.json + decisions.md(마지막 5) + analysis.md + trade_log.md(마지막 3) 로드
3. 14개 종목 시세 병렬 WebFetch (폴백 체인 1→2→3)
3.5 실패한 종목에 한해 WebSearch 폴백 (§3.5 쿼리 템플릿 + 파싱 + sanity check)
4. 마크투마켓 + 종목별 PnL 계산
5. 의사결정 룰 우선순위로 순회 (차수당 최대 4건 거래, websearch source는 보수적)
6. 체결 시뮬레이션 (수수료 차감)
7. portfolio.json + trade_log.md + decisions.md + history.jsonl(append) + latest_snapshot.json 갱신
8. cycle == 3이면 일일 요약 추가
9. git add -A && git commit -m "cycle N — YYYY-MM-DD HH:MM KST" && git push origin main
10. cycle == 3이면 일일 요약 블록을 최종 응답으로 출력 (라우틴 실행 기록에 표시됨)
```

## 11. Git 커밋 규칙

- 메시지: `"cycle {1|2|3} — {YYYY-MM-DD HH:MM} KST"` (예: `"cycle 1 — 2026-05-06 09:37 KST"`)
- 휴장일 스킵 시: `"skip holiday — YYYY-MM-DD"`
- 데이터 결측 시: `"cycle {N} partial — {YYYY-MM-DD HH:MM} KST (data missing)"`
- push 실패 시: 1회 재시도, 그래도 실패하면 routine 응답에 ERROR로 명시

---

## 부록: 종목 코드/거래소 빠른참조

KOSPI: 005930, 000660, 005380, 105560, 207940
KOSDAQ: 196170, 950160(벤치마크 only)
ETF (KRX): 069500, 229200, 091160, 373220, 305720, 161510

google_url 패턴: KOSPI는 `:KRX`, KOSDAQ는 `:KOSDAQ`, ETF는 `:KRX`
