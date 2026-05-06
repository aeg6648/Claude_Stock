#Requires -Version 5.1
<#
rebalance.ps1
원클릭 포트폴리오 처리: 시세조회 → 룰적용 → 매매 → 갱신 → 푸시 → 대시보드.
실행 흐름:
1. git pull
2. 한경에서 13종목 시세 추출
3. AGGRESSIVE 룰 적용해 결정 (최대 4건 거래)
4. portfolio.json / trade_log.md / decisions.md / latest_snapshot.json / history.jsonl 갱신
5. build_dashboard.ps1 호출해 dashboard.html + trades.html 재빌드
6. git commit + push
7. 브라우저에서 dashboard.html 오픈
#>

$ErrorActionPreference = 'Stop'
$PortfolioRoot = Split-Path -Parent $PSScriptRoot
$DashboardScript = Join-Path $PSScriptRoot 'build_dashboard.ps1'
$DashboardHtml = Join-Path $PSScriptRoot 'dashboard.html'

Set-Location $PortfolioRoot
$nowKst = Get-Date -Format 'yyyy-MM-ddTHH:mm:ss+09:00'
$nowDate = Get-Date -Format 'yyyy-MM-dd'
$nowTime = Get-Date -Format 'HH:mm'

Write-Host ('[1/7] git pull ' + $nowKst) -ForegroundColor Cyan
& git pull --rebase origin main 2>&1 | ForEach-Object { Write-Host "  $_" }

# ---- helpers ----
function Get-HankyungPrice {
    param([string]$Code)
    try {
        $resp = Invoke-WebRequest -Uri "https://markets.hankyung.com/stock/$Code" `
            -UserAgent "Mozilla/5.0 (Windows NT 10.0; Win64; x64)" `
            -UseBasicParsing -TimeoutSec 15
        $oneline = ($resp.Content -replace "[\r\n]+", ' ')
        $price = $null; $change = $null
        if ($oneline -match 'stock-data txt-num[^"]*"[^<]*<p class="price">\s*([0-9,]+)') {
            $price = [int]([string]$matches[1] -replace ',', '')
        }
        if ($oneline -match 'class="rate">([+-]?[0-9.]+)%') {
            $change = [double]$matches[1]
        }
        if ($null -eq $price) { return $null }
        return [PSCustomObject]@{ price = $price; change_pct = ($change -as [double]); fetched_at = $nowKst; source = 'hankyung_curl' }
    } catch { return $null }
}

function Format-KRW { param([double]$v) ('₩' + ('{0:N0}' -f [math]::Round($v))) }

# ---- step 2: prices ----
Write-Host '[2/7] 한경 13종목 시세 조회' -ForegroundColor Cyan
$watchlist = Get-Content (Join-Path $PortfolioRoot 'watchlist.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$portfolio = Get-Content (Join-Path $PortfolioRoot 'portfolio.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$snapshot = Get-Content (Join-Path $PortfolioRoot 'latest_snapshot.json') -Raw -Encoding UTF8 | ConvertFrom-Json

$prices = @{}
$tickerCodes = @($watchlist.tickers | ForEach-Object { $_.code })
$benchCodes = @($watchlist.benchmarks | ForEach-Object { $_.code })
$allCodes = $tickerCodes + $benchCodes
foreach ($code in $allCodes) {
    $p = Get-HankyungPrice -Code $code
    if ($null -ne $p) {
        $prices[$code] = $p
        $sign = if ($p.change_pct -gt 0) { '+' } else { '' }
        Write-Host ("  {0} = {1} ({2}{3:N2}%)" -f $code, (Format-KRW $p.price), $sign, $p.change_pct)
    } else {
        Write-Host "  $code = FAILED" -ForegroundColor Red
    }
}

# ---- step 3: rules + decisions ----
Write-Host '[3/7] AGGRESSIVE 룰 적용 + 의사결정' -ForegroundColor Cyan

# 현재 포트 상태 (mark-to-market with fresh prices)
$cash = [double]$portfolio.cash_krw
$startingCapital = [double]$portfolio.starting_capital_krw
$feesPaid = [double]$portfolio.fees_paid_total_krw
$realizedPnl = [double]$portfolio.realized_pnl_krw

# Build position map
$positions = @{}
$positionsObj = $portfolio.positions
if ($null -ne $positionsObj -and $positionsObj -is [PSCustomObject]) {
    foreach ($prop in $positionsObj.PSObject.Properties) {
        $code = $prop.Name
        $p = $positionsObj.$code
        $positions[$code] = [PSCustomObject]@{
            code = $code
            name = $p.name
            shares = [int]$p.shares
            avg_cost = [double]$p.avg_cost_krw
            target_weight = [double]$p.target_weight_pct
            bucket = [string]$p.bucket
            first_buy_date = [string]$p.first_buy_date
            exchange = [string]$p.exchange
        }
    }
}

# Compute total equity (mark-to-market)
$positionsValue = 0.0
foreach ($code in $positions.Keys) {
    $pos = $positions[$code]
    $px = if ($prices.ContainsKey($code)) { [double]$prices[$code].price } else { $pos.avg_cost }
    $positionsValue += $pos.shares * $px
}
$totalEquity = $cash + $positionsValue

# Watchlist target map
$targetMap = @{}
$nameMap = @{}
$bucketMap = @{}
$exchangeMap = @{}
foreach ($t in $watchlist.tickers) {
    $targetMap[$t.code] = [double]$t.target_weight_pct
    $nameMap[$t.code] = [string]$t.name
    $bucketMap[$t.code] = [string]$t.bucket
    $exchangeMap[$t.code] = [string]$t.exchange
}

# Decisions list
$decisions = @()  # array of [PSCustomObject]
$tradeCount = 0
$maxTrades = 4
$cashFloorPct = 0.0  # AGGRESSIVE
$buyCommissionPct = [double]$portfolio.fee_model.buy_commission_pct / 100.0
$sellCommissionPct = [double]$portfolio.fee_model.sell_commission_pct / 100.0
$sellTaxPct = [double]$portfolio.fee_model.sell_tax_pct / 100.0

# Rule priority for each ticker:
# 1. Loss-stop -15% (강제 SELL)
# 2. Profit-take +30% → 1/4 SELL
# 3. Single name >30% → trim
# 4. legacy_to_exit (target=0) → SELL all
# 5. >+10% chase → no buy
# 6. Momentum +5~+10% → BUY 50% target
# 7. Drop ≤-1.5% → BUY 50% target
# 8. Range -1.5~+5% → BUY 50% target
# 9. HOLD

$rulesEvaluated = @()
foreach ($t in $watchlist.tickers) {
    $code = $t.code
    if (-not $prices.ContainsKey($code)) {
        $rulesEvaluated += "${code}: 시세 결측 - 결정 스킵"
        continue
    }
    $px = [double]$prices[$code].price
    $chPct = [double]$prices[$code].change_pct
    $targetPct = [double]$t.target_weight_pct
    $bucket = [string]$t.bucket
    $name = [string]$t.name

    $heldShares = if ($positions.ContainsKey($code)) { [int]$positions[$code].shares } else { 0 }
    $heldValue = $heldShares * $px
    $heldWeight = if ($totalEquity -gt 0) { ($heldValue / $totalEquity) * 100.0 } else { 0.0 }
    $avgCost = if ($positions.ContainsKey($code)) { [double]$positions[$code].avg_cost } else { 0.0 }
    $unrealPct = if ($avgCost -gt 0) { (($px - $avgCost) / $avgCost) * 100.0 } else { 0.0 }

    # Rule 4: legacy_to_exit
    if ($bucket -eq 'legacy_to_exit' -and $heldShares -gt 0) {
        $decisions += [PSCustomObject]@{ type='SELL'; code=$code; name=$name; shares=$heldShares; price=$px; reason="Rule 4 강제 퇴출 (legacy_to_exit)" }
        $rulesEvaluated += "${code}: Rule 4 → SELL all $heldShares주"
        continue
    }
    # Rule 1: Loss-stop -15%
    if ($heldShares -gt 0 -and $unrealPct -le -15.0) {
        $decisions += [PSCustomObject]@{ type='SELL'; code=$code; name=$name; shares=$heldShares; price=$px; reason="Rule 1 손절 ($('{0:F2}' -f $unrealPct)%)" }
        $rulesEvaluated += "${code}: Rule 1 → SELL all (-${unrealPct}%)"
        continue
    }
    # Rule 2: Profit-take +30% → 1/4 sell
    if ($heldShares -gt 0 -and $unrealPct -ge 30.0) {
        $sellShares = [Math]::Floor($heldShares / 4.0)
        if ($sellShares -ge 1) {
            $decisions += [PSCustomObject]@{ type='SELL'; code=$code; name=$name; shares=$sellShares; price=$px; reason="Rule 2 익절 1/4 (+$('{0:F2}' -f $unrealPct)%)" }
            $rulesEvaluated += "${code}: Rule 2 → SELL ${sellShares}주 (1/4)"
            continue
        }
    }
    # Rule 3: Single name >30%
    if ($heldWeight -gt 30.0) {
        $excessValue = ($heldWeight - 30.0) / 100.0 * $totalEquity
        $sellShares = [int][Math]::Ceiling($excessValue / $px)
        if ($sellShares -gt 0 -and $sellShares -le $heldShares) {
            $decisions += [PSCustomObject]@{ type='SELL'; code=$code; name=$name; shares=$sellShares; price=$px; reason="Rule 3 비중 cap 30% 초과 trim (현재 $('{0:F2}' -f $heldWeight)%)" }
            $rulesEvaluated += "${code}: Rule 3 → SELL ${sellShares}주 (cap)"
            continue
        }
    }

    # Rule 5: chase block (>+10%)
    if ($chPct -ge 10.0) {
        $rulesEvaluated += "${code}: Rule 5 chase block (+$('{0:F2}' -f $chPct)%) - HOLD"
        continue
    }

    # Buy rules — only if held < target × 0.5
    $halfTargetWeight = $targetPct * 0.5
    if ($targetPct -le 0) {
        $rulesEvaluated += "${code}: target=0 - HOLD"
        continue
    }
    if ($heldWeight -ge $halfTargetWeight) {
        $rulesEvaluated += ("{0}: held {1:F2}% >= target/2 {2:F2}% - HOLD" -f $code, $heldWeight, $halfTargetWeight)
        continue
    }

    # Determine which buy rule fires
    $rule = $null
    if ($chPct -ge 5.0 -and $chPct -lt 10.0) { $rule = '6 모멘텀' }
    elseif ($chPct -le -1.5) { $rule = '7 눌림' }
    elseif ($chPct -gt -1.5 -and $chPct -lt 5.0) { $rule = '8 횡보' }
    if ($null -eq $rule) {
        $rulesEvaluated += "${code}: 매수 룰 미매치 - HOLD"
        continue
    }

    # Buy size: target × 50% of total equity, in shares (floor)
    $buyTargetKrw = ($targetPct * 0.5 / 100.0) * $totalEquity
    $buyShares = [int][Math]::Floor($buyTargetKrw / $px)
    if ($buyShares -lt 1) {
        $rulesEvaluated += "${code}: 매수 단위 1주 미만 - HOLD"
        continue
    }
    $decisions += [PSCustomObject]@{ type='BUY'; code=$code; name=$name; shares=$buyShares; price=$px; reason="Rule $rule (일중 $('{0:F2}' -f $chPct)%)" }
    $rulesEvaluated += "${code}: Rule $rule → BUY ${buyShares}주"
}

# Cap to maxTrades (priority: SELL first, then BUY ordered by largest deficit)
$sellList = @($decisions | Where-Object { $_.type -eq 'SELL' })
$buyList = @($decisions | Where-Object { $_.type -eq 'BUY' })
# Sort BUY by current weight deficit (smallest weight first = highest priority)
$buyList = $buyList | Sort-Object @{ Expression = {
    $code = $_.code
    $heldShares = if ($positions.ContainsKey($code)) { [int]$positions[$code].shares } else { 0 }
    $px = [double]$_.price
    $heldVal = $heldShares * $px
    $heldW = if ($totalEquity -gt 0) { ($heldVal / $totalEquity) * 100.0 } else { 0.0 }
    $tgt = [double]$targetMap[$code]
    return $heldW - $tgt   # most negative first = highest deficit
}}

$selectedDecisions = @()
foreach ($d in $sellList) {
    if ($selectedDecisions.Count -lt $maxTrades) { $selectedDecisions += $d }
}
foreach ($d in $buyList) {
    if ($selectedDecisions.Count -lt $maxTrades) { $selectedDecisions += $d }
}

Write-Host ("  결정: {0}건 (최대 {1})" -f $selectedDecisions.Count, $maxTrades)
foreach ($d in $selectedDecisions) {
    Write-Host ("    {0} {1} {2} {3}주 @ {4} -- {5}" -f $d.type, $d.code, $d.name, $d.shares, (Format-KRW $d.price), $d.reason)
}

# ---- step 4: execute trades ----
Write-Host '[4/7] 모의 체결 + 파일 갱신' -ForegroundColor Cyan
$tradeLogPath = Join-Path $PortfolioRoot 'trade_log.md'
$decisionsPath = Join-Path $PortfolioRoot 'decisions.md'

$newTradeBlocks = ''
foreach ($d in $selectedDecisions) {
    $code = $d.code; $name = $d.name; $shares = [int]$d.shares; $px = [double]$d.price
    $notional = $shares * $px
    if ($d.type -eq 'BUY') {
        $commission = [Math]::Round($notional * $buyCommissionPct)
        $totalCost = $notional + $commission
        $cash -= $totalCost
        $feesPaid += $commission
        if ($positions.ContainsKey($code)) {
            $oldShares = [int]$positions[$code].shares
            $oldAvg = [double]$positions[$code].avg_cost
            $newShares = $oldShares + $shares
            $newAvg = (($oldShares * $oldAvg) + ($shares * $px)) / $newShares
            $positions[$code].shares = $newShares
            $positions[$code].avg_cost = [Math]::Round($newAvg)
        } else {
            $positions[$code] = [PSCustomObject]@{
                code = $code; name = $name; shares = $shares; avg_cost = [double]$px
                target_weight = [double]$targetMap[$code]; bucket = [string]$bucketMap[$code]
                first_buy_date = $nowDate; exchange = [string]$exchangeMap[$code]
            }
        }
        $newTradeBlocks += @"

## $nowDate $nowTime KST | BUY | $code $name [Rebalance]
- 수량: $shares주 @ $(Format-KRW $px)
- 체결금액: $(Format-KRW $notional)
- 수수료: $(Format-KRW $commission) (커미션)
- 사유: $($d.reason)
- 사후 보유: $($positions[$code].shares)주, 평단 $(Format-KRW $positions[$code].avg_cost)
- 포트 현금: $(Format-KRW $cash)
"@
    } else {
        # SELL
        $commission = [Math]::Round($notional * $sellCommissionPct)
        $tax = [Math]::Round($notional * $sellTaxPct)
        $totalFee = $commission + $tax
        $proceeds = $notional - $totalFee
        $cash += $proceeds
        $feesPaid += $totalFee
        $oldShares = [int]$positions[$code].shares
        $oldAvg = [double]$positions[$code].avg_cost
        $realizedThis = $proceeds - ($shares * $oldAvg)
        $realizedPnl += $realizedThis
        $remaining = $oldShares - $shares
        if ($remaining -le 0) {
            $positions.Remove($code) | Out-Null
            $afterShares = 0
            $afterAvg = 0
        } else {
            $positions[$code].shares = $remaining
            $afterShares = $remaining
            $afterAvg = $oldAvg
        }
        $newTradeBlocks += @"

## $nowDate $nowTime KST | SELL | $code $name [Rebalance]
- 수량: $shares주 @ $(Format-KRW $px)
- 체결금액: $(Format-KRW $notional)
- 수수료: $(Format-KRW $commission) (커미션) + $(Format-KRW $tax) (거래세) = $(Format-KRW $totalFee)
- 실현손익: $(Format-KRW $realizedThis)
- 사유: $($d.reason)
- 사후 보유: $afterShares주$(if ($afterShares -gt 0) { ", 평단 $(Format-KRW $afterAvg)" } else { ' (포지션 삭제)' })
- 포트 현금: $(Format-KRW $cash)
"@
    }
}

# Append to trade_log.md
if ($selectedDecisions.Count -gt 0) {
    Add-Content -Path $tradeLogPath -Value $newTradeBlocks -Encoding UTF8
}

# Recompute mark-to-market with fresh prices
$positionsValue = 0.0
foreach ($code in $positions.Keys) {
    $pos = $positions[$code]
    $px = if ($prices.ContainsKey($code)) { [double]$prices[$code].price } else { [double]$pos.avg_cost }
    $positionsValue += $pos.shares * $px
}
$totalEquity = $cash + $positionsValue
$totalPnl = $totalEquity - $startingCapital
$totalPnlPct = ($totalPnl / $startingCapital) * 100.0

# Write portfolio.json
$portfolioOut = [ordered]@{
    as_of = $nowKst
    starting_capital_krw = [int]$startingCapital
    cash_krw = [int][Math]::Round($cash)
    positions = [ordered]@{}
    fees_paid_total_krw = [int]$feesPaid
    realized_pnl_krw = [int][Math]::Round($realizedPnl)
    fee_model = $portfolio.fee_model
}
foreach ($code in ($positions.Keys | Sort-Object)) {
    $pos = $positions[$code]
    $portfolioOut.positions[$code] = [ordered]@{
        code = $code; name = [string]$pos.name; exchange = [string]$pos.exchange
        shares = [int]$pos.shares; avg_cost_krw = [int][Math]::Round($pos.avg_cost)
        first_buy_date = [string]$pos.first_buy_date
        target_weight_pct = [double]$pos.target_weight; bucket = [string]$pos.bucket
    }
}
$utf8NoBom = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllText((Join-Path $PortfolioRoot 'portfolio.json'), ($portfolioOut | ConvertTo-Json -Depth 10), $utf8NoBom)

# Update latest_snapshot.json
$bench = $snapshot.benchmarks
$kospi200StartPrice = if ($null -ne $bench.kospi200_start_price) { [double]$bench.kospi200_start_price } else { 0.0 }
$kolonStartPrice = if ($null -ne $bench.kolon_tissuegene_start_price) { [double]$bench.kolon_tissuegene_start_price } else { 0.0 }
$kospi200CurPx = if ($prices.ContainsKey('069500')) { [double]$prices['069500'].price } else { [double]$bench.kospi200_current_price }
$kolonCurPx = if ($prices.ContainsKey('950160')) { [double]$prices['950160'].price } else { [double]$bench.kolon_tissuegene_current_price }
$kospiRet = if ($kospi200StartPrice -gt 0) { (($kospi200CurPx - $kospi200StartPrice) / $kospi200StartPrice) * 100.0 } else { 0.0 }
$kolonRet = if ($kolonStartPrice -gt 0) { (($kolonCurPx - $kolonStartPrice) / $kolonStartPrice) * 100.0 } else { 0.0 }

$snapPositions = @()
foreach ($code in $positions.Keys) {
    $pos = $positions[$code]
    $px = if ($prices.ContainsKey($code)) { [double]$prices[$code].price } else { [double]$pos.avg_cost }
    $val = $pos.shares * $px
    $unreal = $val - ($pos.shares * $pos.avg_cost)
    $unrealPct = if ($pos.avg_cost -gt 0) { (($px - $pos.avg_cost) / $pos.avg_cost) * 100.0 } else { 0.0 }
    $weight = if ($totalEquity -gt 0) { ($val / $totalEquity) * 100.0 } else { 0.0 }
    $snapPositions += [ordered]@{
        code = $code; name = [string]$pos.name; shares = [int]$pos.shares
        avg_cost = [int][Math]::Round($pos.avg_cost); last_price = [int]$px
        unrealized_pnl_krw = [int][Math]::Round($unreal)
        unrealized_pnl_pct = [double]([Math]::Round($unrealPct, 2))
        weight_pct = [double]([Math]::Round($weight, 2))
    }
}

$pricesOut = [ordered]@{}
foreach ($code in $prices.Keys) {
    $pricesOut[$code] = [ordered]@{
        price = [int]$prices[$code].price
        change_pct = [double]$prices[$code].change_pct
        fetched_at = $nowKst
        source = 'hankyung_curl'
    }
}

$snapshotOut = [ordered]@{
    as_of = $nowKst
    cycle = 'rebalance_local'
    note = 'rebalance.bat 트리거. 사용자 클릭 시점에 한경 fresh 가격 + AGGRESSIVE 룰 적용.'
    portfolio = [ordered]@{
        cash_krw = [int][Math]::Round($cash)
        positions_value_krw = [int][Math]::Round($positionsValue)
        total_equity_krw = [int][Math]::Round($totalEquity)
        total_pnl_krw = [int][Math]::Round($totalPnl)
        total_pnl_pct = [double]([Math]::Round($totalPnlPct, 4))
        fees_paid_total_krw = [int]$feesPaid
        realized_pnl_krw = [int][Math]::Round($realizedPnl)
    }
    positions = $snapPositions
    prices = $pricesOut
    benchmarks = [ordered]@{
        kospi200_start_price = [int]$kospi200StartPrice
        kospi200_current_price = [int]$kospi200CurPx
        kospi200_return_pct = [double]([Math]::Round($kospiRet, 3))
        kolon_tissuegene_start_price = [int]$kolonStartPrice
        kolon_tissuegene_current_price = [int]$kolonCurPx
        kolon_tissuegene_return_pct = [double]([Math]::Round($kolonRet, 3))
        user_kolon_position_value_krw = [int]([Math]::Round(5290 * $kolonCurPx))
        user_kolon_shares = 5290
        user_kolon_avg_cost_krw = 47660
        my_portfolio_return_pct = [double]([Math]::Round($totalPnlPct, 4))
    }
}
[System.IO.File]::WriteAllText((Join-Path $PortfolioRoot 'latest_snapshot.json'), ($snapshotOut | ConvertTo-Json -Depth 10), $utf8NoBom)

# Append to history.jsonl
$historyEntry = '{"as_of": "' + $nowKst + '", "cycle": "rebalance_local", "my_value_krw": ' + [int][Math]::Round($totalEquity) + ', "kospi200_price": ' + [int]$kospi200CurPx + ', "kolon_price": ' + [int]$kolonCurPx + '}'
Add-Content -Path (Join-Path $PortfolioRoot 'history.jsonl') -Value $historyEntry -Encoding UTF8

# Append decisions.md
$decisionBlock = "`r`n---`r`n`r`n## $nowDate $nowTime KST [Rebalance — 사용자 트리거]`r`n`r`n### 시세 (한경 curl)`r`n"
$decisionBlock += "| 종목 | 코드 | 현재가 | 일중 % |`r`n|---|---|---|---|`r`n"
foreach ($code in $allCodes) {
    if ($prices.ContainsKey($code)) {
        $pp = $prices[$code]
        $nm = if ($nameMap.ContainsKey($code)) { $nameMap[$code] } else { $code }
        $sgn = if ($pp.change_pct -gt 0) { '+' } else { '' }
        $decisionBlock += ("| {0} | {1} | {2} | {3}{4:F2}% |`r`n" -f $nm, $code, (Format-KRW $pp.price), $sgn, $pp.change_pct)
    }
}
$decisionBlock += "`r`n### 룰 평가`r`n"
foreach ($r in $rulesEvaluated) { $decisionBlock += "- $r`r`n" }
$decisionBlock += "`r`n### 결정 ($($selectedDecisions.Count)건 / 최대 $maxTrades)`r`n"
foreach ($d in $selectedDecisions) {
    $decisionBlock += "- **$($d.type) $($d.code) $($d.name)** $($d.shares)주 @ $(Format-KRW $d.price) — $($d.reason)`r`n"
}
$decisionBlock += "`r`n### 포트폴리오 사후`r`n"
$decisionBlock += "- 총 평가: $(Format-KRW $totalEquity) ($('{0:+0.00;-0.00;0.00}' -f $totalPnlPct)%)`r`n"
$decisionBlock += "- 현금: $(Format-KRW $cash) / 주식: $(Format-KRW $positionsValue)`r`n"
$decisionBlock += "- 누적 수수료: $(Format-KRW $feesPaid) / 실현손익: $(Format-KRW $realizedPnl)`r`n"
$decisionBlock += "`r`n### 벤치마크`r`n"
$decisionBlock += ("- KOSPI 200: {0} ({1:+0.00;-0.00;0.00}%)`r`n" -f (Format-KRW $kospi200CurPx), $kospiRet)
$decisionBlock += ("- 코오롱티슈진: {0} ({1:+0.00;-0.00;0.00}%)`r`n" -f (Format-KRW $kolonCurPx), $kolonRet)
Add-Content -Path $decisionsPath -Value $decisionBlock -Encoding UTF8

# ---- step 5: rebuild dashboard ----
Write-Host '[5/7] 대시보드 재빌드' -ForegroundColor Cyan
& $DashboardScript

# ---- step 6: git commit + push ----
Write-Host '[6/7] git commit + push' -ForegroundColor Cyan
& git add -A 2>&1 | Out-Null
$commitMsg = "rebalance_local — $nowDate $nowTime KST ($($selectedDecisions.Count) trades)"
& git commit -m $commitMsg 2>&1 | ForEach-Object { Write-Host "  $_" }
& git push origin main 2>&1 | ForEach-Object { Write-Host "  $_" }

# ---- step 7: open dashboard ----
Write-Host '[7/7] 대시보드 오픈' -ForegroundColor Cyan
Start-Process $DashboardHtml

Write-Host ''
Write-Host '=== 완료 ===' -ForegroundColor Green
Write-Host ("총평가: {0} ({1:+0.00;-0.00;0.00}%)" -f (Format-KRW $totalEquity), $totalPnlPct)
Write-Host ("vs KOSPI 200: {0:+0.00;-0.00;0.00}%" -f $kospiRet)
Write-Host ("vs 코오롱티슈진: {0:+0.00;-0.00;0.00}%" -f $kolonRet)
