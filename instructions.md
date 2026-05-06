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

**폴백 체인 (종목당 순서대로 시도)**:
1. `google_url`로 WebFetch — 가장 신뢰
2. 실패 시 `hankyung_url`로 WebFetch
3. 실패 시 `investing_url` (있는 경우)
4. 모두 실패 → 해당 종목 결측 처리, decisions.md에 기록, 그 차수 매매 결정 스킵

**병렬 호출 권장**: 12종목+벤치마크 2개 = 14개 WebFetch를 한 메시지에 병렬로 보낸다.

**WebFetch 프롬프트 표준**:
```
Extract: current price (KRW integer), change (KRW), change_pct (number), day_high, day_low, previous_close, timestamp. Return JSON only.
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

## 5. 의사결정 룰 (종목별 순회)

각 종목에 대해 우선순위대로 평가, **첫 매치되는 룰만 실행**:

| 우선순위 | 조건 | 행동 |
|---|---|---|
| 1 (강제) | 평단 대비 -10% 이하 | 전량 매도 (손절) |
| 2 (강제) | 평단 대비 +20% 이상 | 1/3 매도 (익절) |
| 3 (제한) | 단일 종목 비중 > 25% | 25% 초과분 매도 |
| 4 (금지) | 일중 +5% 이상 급등 | 신규/추가매수 차단 |
| 5 (매수) | 보유비중 < 목표비중 × 0.5 AND 일중 -2% 이상 하락 | 분할매수 1단위 (목표비중의 25%만큼) |
| 6 (매수) | 보유비중 < 목표비중 × 0.5 AND 일중 변동 -1%~+1% | 분할매수 1단위 (목표비중의 25%만큼) |
| 7 (보유) | 위 조건 모두 미해당 | HOLD |

**전역 가드**:
- 차수당 최대 신규 거래 2건 (오버트레이딩 방지)
- 현금 비중 < 5% → 매수 전면 정지
- WebFetch 결측 종목 → 그 차수 결정 스킵

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

4. `latest_snapshot.json` 덮어쓰기 — 대시보드용:
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

- WebFetch 일부 실패: 결측 종목만 스킵하고 나머지는 정상 진행
- WebFetch 전부 실패: portfolio.json 변경하지 말 것, decisions.md에 "데이터 수집 실패" 한 줄만 기록
- Write 실패: 같은 파일 한 번 더 시도, 또 실패하면 사용자에게 알림 (cycle 무관)
- 절대 추측해서 거래하지 말 것 — 데이터 없으면 보유

## 10. 실행 순서 요약

```
0. git pull --rebase origin main
1. 휴장/주말 체크
2. portfolio.json + watchlist.json + decisions.md(마지막 5) + analysis.md + trade_log.md(마지막 3) 로드
3. 14개 종목 시세 병렬 WebFetch (폴백 체인)
4. 마크투마켓 + 종목별 PnL 계산
5. 의사결정 룰 우선순위로 순회 (차수당 최대 2건 거래)
6. 체결 시뮬레이션 (수수료 차감)
7. portfolio.json + trade_log.md + decisions.md + latest_snapshot.json 갱신
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
