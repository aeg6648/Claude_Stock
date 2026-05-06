# Korean Stock Mock Portfolio (₩100,000,000)

**Purpose**: 사용자가 Claude의 분석/판단 능력을 검증하기 위한 모의 운용.
**Period**: 2026-05-06 ~ ~2026-08-05 (~64거래일, 3개월).
**Strategy**: AGGRESSIVE (공격형) — 집중 / 모멘텀 추격 / 레버리지 ETF / 풀 익스포저
**Cadence**: 사용자 트리거 시에만 (manual mode)
**Mechanism**: 사용자가 채팅으로 "사이클 돌려줘" / "rebalance" / "오늘 마감 정리" 같이 요청 → Claude가 fresh 가격 조회 + 결정 + 파일 갱신 + git push. 클라우드 routine은 비활성화 (WebFetch/curl 모두 cloud env에서 차단되어 stale 데이터 문제 발생, 옵션 C로 전환).

## ⚠️ 이것은 투자 자문이 아닙니다

모든 의사결정은 모델 능력 평가 목적의 시뮬레이션이며, 실제 매매에 활용해서는 안 됩니다.

## 사용법

### 🔁 한 번 클릭으로 자동 처리 (권장)
**`dashboard\rebalance.bat`** 더블클릭 → 모든 작업 자동:
1. git pull (최신 상태 동기화)
2. 한경 13종목 fresh 시세 수집 (curl + Mozilla UA)
3. AGGRESSIVE 룰 적용 + 의사결정 (최대 4건 거래)
4. 모의 체결 (수수료/세금 정확 차감)
5. portfolio.json / trade_log.md / decisions.md / latest_snapshot.json / history.jsonl 갱신
6. dashboard.html + trades.html 재빌드
7. git commit + push (커밋 메시지: `rebalance_local — YYYY-MM-DD HH:MM KST (N trades)`)
8. 브라우저에서 dashboard.html 자동 오픈

매 클릭이 1 cycle. 시장 시간 중에 누르면 그 시점 가격으로, 마감 후 누르면 종가로 작업.

### 👁️ 보기만 (매매 없이 시각화만)
**`dashboard\view.bat`** 더블클릭 → git pull + dashboard.html 빌드 + 오픈. 룰 적용/거래 없음.

### 📋 거래 기록 페이지
dashboard.html → **"📋 전체 거래 기록 보기"** 버튼 클릭 → trades.html (필터/정렬)

### 💬 Claude에게 직접 요청 (개별 판단 필요 시)
복잡한 결정 (예: 전략 변경, 코오롱티슈진 분석, 룰 외 강제 매매)은 채팅에서 직접 요청.

## 파일 역할

| 파일 | 역할 |
|---|---|
| `instructions.md` | 의사결정 룰 + 데이터 소스 폴백 체인 (런북) |
| `portfolio.json` | 현재 보유 (현금/종목/평단) — 매 거래 시 갱신 |
| `watchlist.json` | 모니터링 종목 + 버킷별 목표 비중 |
| `holidays.json` | 2026 한국증시 휴장일 |
| `trade_log.md` | 체결된 거래 append-only (감사 기록) |
| `decisions.md` | 사이클별 결정 append-only (시세 + 판단 + 사유) |
| `latest_snapshot.json` | 최신 마크투마켓 스냅샷 (대시보드 입력) |
| `history.jsonl` | 사이클별 시계열 (차트용) |
| `analysis.md` | 시장관/장기 논리 (선택적 갱신) |
| `dashboard/dashboard.html` | 메인 대시보드 (계좌·차트·보유·최근거래) |
| `dashboard/trades.html` | 전체 거래 기록 페이지 (필터링) |

## 한계

1. 시세 15~20분 지연 (단타 불가)
2. 모의 체결가 = 조회 시점 가격 (호가/슬리피지 미반영)
3. 한 종목 데이터 결측 시 그 차수에서 해당 종목 의사결정 스킵
4. 뉴스/펀더멘털은 매 차수 WebSearch 헤드라인 수준
5. 휴장일은 `holidays.json` 수동 유지 (자동 인식 안 됨)
