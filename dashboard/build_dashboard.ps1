#Requires -Version 5.1
<#
build_dashboard.ps1
모의 포트폴리오 상태를 읽어 dashboard.html을 생성하고 기본 브라우저로 연다.
재부팅과 무관하게 디스크의 JSON/MD 파일을 그대로 읽으므로 항상 최신 상태를 보여준다.
#>

$ErrorActionPreference = 'Stop'
$PortfolioRoot = Split-Path -Parent $PSScriptRoot
$OutHtml = Join-Path $PSScriptRoot 'dashboard.html'

function Read-JsonFile {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $null }
    return (Get-Content -Path $Path -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function Read-TextFile {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return '' }
    return (Get-Content -Path $Path -Raw -Encoding UTF8)
}

function Format-KRW {
    param([double]$Value)
    return ('₩' + ('{0:N0}' -f [math]::Round($Value)))
}

function Format-Pct {
    param([double]$Value, [int]$Digits = 2)
    $sign = if ($Value -gt 0) { '+' } else { '' }
    $fmt = '{0:N' + $Digits + '}'
    return ($sign + ($fmt -f $Value) + '%')
}

function Encode-Html {
    param([string]$Text)
    if ($null -eq $Text) { return '' }
    return $Text.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;')
}

function Get-PnlClass {
    param([double]$Value)
    if ($Value -gt 0) { return 'pos' }
    if ($Value -lt 0) { return 'neg' }
    return 'zero'
}

# === 데이터 로드 ===
$portfolio = Read-JsonFile (Join-Path $PortfolioRoot 'portfolio.json')
$watchlist = Read-JsonFile (Join-Path $PortfolioRoot 'watchlist.json')
$snapshot  = Read-JsonFile (Join-Path $PortfolioRoot 'latest_snapshot.json')
$tradeLog  = Read-TextFile (Join-Path $PortfolioRoot 'trade_log.md')
$decisions = Read-TextFile (Join-Path $PortfolioRoot 'decisions.md')

# history.jsonl 로드 (한 줄 = 한 cycle 스냅샷)
$historyPath = Join-Path $PortfolioRoot 'history.jsonl'
$historyEntries = @()
if (Test-Path $historyPath) {
    $lines = Get-Content -Path $historyPath -Encoding UTF8 | Where-Object { $_ -match '\S' }
    foreach ($ln in $lines) {
        try { $historyEntries += ($ln | ConvertFrom-Json) } catch { }
    }
}

if ($null -eq $portfolio) {
    Write-Host 'portfolio.json을 찾지 못했습니다.' -ForegroundColor Red
    exit 1
}

# 종목명 매핑 (watchlist에서)
$nameMap = @{}
$bucketMap = @{}
$targetWeightMap = @{}
if ($null -ne $watchlist) {
    foreach ($t in $watchlist.tickers) {
        $nameMap[$t.code] = $t.name
        $bucketMap[$t.code] = $t.bucket
        $targetWeightMap[$t.code] = $t.target_weight_pct
    }
}

# === 계좌 요약 계산 ===
$startingCapital = [double]$portfolio.starting_capital_krw
$cash = [double]$portfolio.cash_krw
$feesPaid = [double]$portfolio.fees_paid_total_krw
$realizedPnl = [double]$portfolio.realized_pnl_krw

$positionsValue = 0.0
$positionsRows = @()

if ($null -ne $snapshot -and $null -ne $snapshot.portfolio) {
    $positionsValue = [double]$snapshot.portfolio.positions_value_krw
}

# 보유 종목 행 생성 (snapshot 우선, fallback portfolio.json)
$positionsObj = $portfolio.positions
$hasPositions = $false
if ($null -ne $positionsObj -and $positionsObj -is [PSCustomObject]) {
    $props = @($positionsObj.PSObject.Properties | Where-Object { $_ -and $_.Name })
    if ($props.Count -gt 0) { $hasPositions = $true }

    foreach ($prop in $props) {
        $code = $prop.Name
        if ([string]::IsNullOrWhiteSpace($code)) { continue }
        $p = $positionsObj.$code
        $shares = [double]$p.shares
        $avgCost = [double]$p.avg_cost_krw
        $costValue = $shares * $avgCost

        $lastPrice = $avgCost  # 기본값: 평단 (snapshot 없을 때)
        if ($null -ne $snapshot -and $null -ne $snapshot.prices) {
            $priceEntry = $snapshot.prices.$code
            if ($null -ne $priceEntry) { $lastPrice = [double]$priceEntry.price }
        }

        $marketValue = $shares * $lastPrice
        $unrealized = $marketValue - $costValue
        $unrealizedPct = if ($costValue -gt 0) { ($unrealized / $costValue) * 100 } else { 0 }

        $positionsRows += [PSCustomObject]@{
            Code = $code
            Name = if ($nameMap.ContainsKey($code)) { $nameMap[$code] } else { $p.name }
            Bucket = if ($bucketMap.ContainsKey($code)) { $bucketMap[$code] } else { '' }
            Shares = $shares
            AvgCost = $avgCost
            LastPrice = $lastPrice
            MarketValue = $marketValue
            Unrealized = $unrealized
            UnrealizedPct = $unrealizedPct
            TargetWeight = if ($targetWeightMap.ContainsKey($code)) { $targetWeightMap[$code] } else { 0 }
        }
    }
}

# snapshot이 없으면 portfolio.json 기반으로 합계 재계산
if ($null -eq $snapshot) {
    $positionsValue = ($positionsRows | Measure-Object -Sum MarketValue).Sum
    if ($null -eq $positionsValue) { $positionsValue = 0 }
}

$totalEquity = $cash + $positionsValue
$totalPnl = $totalEquity - $startingCapital
$totalPnlPct = ($totalPnl / $startingCapital) * 100

# === 벤치마크 ===
$bench = if ($null -ne $snapshot) { $snapshot.benchmarks } else { $null }

# === HTML 생성 ===
$asOf = if ($null -ne $snapshot) { $snapshot.as_of } else { $portfolio.as_of }
$cycle = if ($null -ne $snapshot) { $snapshot.cycle } else { '-' }

$summaryClass = Get-PnlClass $totalPnl
$summaryHtml = @"
<section class="summary card">
  <div class="hdr">계좌 총평가액</div>
  <div class="big $summaryClass">$(Format-KRW $totalEquity)</div>
  <div class="sub $summaryClass">$(Format-Pct $totalPnlPct) ($(Format-KRW $totalPnl)) vs 시작금 $(Format-KRW $startingCapital)</div>
  <div class="grid4">
    <div><label>현금</label><span>$(Format-KRW $cash)</span></div>
    <div><label>주식 평가</label><span>$(Format-KRW $positionsValue)</span></div>
    <div><label>실현손익</label><span class="$(Get-PnlClass $realizedPnl)">$(Format-KRW $realizedPnl)</span></div>
    <div><label>누적 수수료</label><span>$(Format-KRW $feesPaid)</span></div>
  </div>
  <div class="meta">최종 갱신: $(Encode-Html $asOf) | Cycle: $(Encode-Html $cycle)</div>
</section>
"@

# 보유 종목 테이블
$positionsHtml = ''
if ($hasPositions) {
    $rows = ''
    foreach ($r in ($positionsRows | Sort-Object MarketValue -Descending)) {
        $weight = if ($totalEquity -gt 0) { ($r.MarketValue / $totalEquity) * 100 } else { 0 }
        $unrealClass = Get-PnlClass $r.Unrealized
        $rows += @"
<tr>
  <td><span class="code">$(Encode-Html $r.Code)</span></td>
  <td>$(Encode-Html $r.Name)</td>
  <td><span class="bucket">$(Encode-Html $r.Bucket)</span></td>
  <td class="num">$('{0:N0}' -f $r.Shares)</td>
  <td class="num">$(Format-KRW $r.AvgCost)</td>
  <td class="num">$(Format-KRW $r.LastPrice)</td>
  <td class="num">$(Format-KRW $r.MarketValue)</td>
  <td class="num $unrealClass">$(Format-KRW $r.Unrealized)<br><small>$(Format-Pct $r.UnrealizedPct)</small></td>
  <td class="num">$(Format-Pct $weight 1)<br><small>목표 $(Format-Pct $r.TargetWeight 0)</small></td>
</tr>
"@
    }
    $positionsHtml = @"
<section class="card">
  <h2>보유 종목</h2>
  <table>
    <thead><tr>
      <th>코드</th><th>종목명</th><th>버킷</th><th class="num">수량</th>
      <th class="num">평단</th><th class="num">현재가</th><th class="num">평가액</th>
      <th class="num">평가손익</th><th class="num">비중</th>
    </tr></thead>
    <tbody>$rows</tbody>
  </table>
</section>
"@
} else {
    $positionsHtml = @"
<section class="card">
  <h2>보유 종목</h2>
  <p class="empty">아직 매수된 종목이 없습니다. 첫 cycle 실행 후 표시됩니다.</p>
</section>
"@
}

# 벤치마크 비교
$benchHtml = ''
if ($null -ne $bench) {
    $myRet = if ($null -ne $bench.my_portfolio_return_pct) { [double]$bench.my_portfolio_return_pct } else { $totalPnlPct }
    $kospiRet = if ($null -ne $bench.kospi200_return_pct) { [double]$bench.kospi200_return_pct } else { 0 }
    $kolonRet = if ($null -ne $bench.kolon_tissuegene_return_pct) { [double]$bench.kolon_tissuegene_return_pct } else { 0 }

    $myClass = Get-PnlClass $myRet
    $kospiClass = Get-PnlClass $kospiRet
    $kolonClass = Get-PnlClass $kolonRet

    # bar width based on absolute return (cap at 30% for visual)
    $barMax = [math]::Max([math]::Abs($myRet), [math]::Max([math]::Abs($kospiRet), [math]::Abs($kolonRet)))
    if ($barMax -lt 1) { $barMax = 1 }

    $myW = [math]::Min(100, [math]::Abs($myRet) / $barMax * 100)
    $kospiW = [math]::Min(100, [math]::Abs($kospiRet) / $barMax * 100)
    $kolonW = [math]::Min(100, [math]::Abs($kolonRet) / $barMax * 100)

    $kolonValue = if ($null -ne $bench.user_kolon_position_value_krw) { [double]$bench.user_kolon_position_value_krw } else { 0 }

    $benchHtml = @"
<section class="card">
  <h2>3-Way 벤치마크 레이스 (운영기간 누적 수익률)</h2>
  <div class="bench">
    <div class="bench-row">
      <div class="bench-label">📊 나의 모의 포트폴리오</div>
      <div class="bench-bar"><div class="bar $myClass" style="width:$myW%"></div></div>
      <div class="bench-val $myClass">$(Format-Pct $myRet)</div>
    </div>
    <div class="bench-row">
      <div class="bench-label">📈 KOSPI 200 (069500)</div>
      <div class="bench-bar"><div class="bar $kospiClass" style="width:$kospiW%"></div></div>
      <div class="bench-val $kospiClass">$(Format-Pct $kospiRet)</div>
    </div>
    <div class="bench-row">
      <div class="bench-label">🧬 코오롱티슈진 (사용자 보유)</div>
      <div class="bench-bar"><div class="bar $kolonClass" style="width:$kolonW%"></div></div>
      <div class="bench-val $kolonClass">$(Format-Pct $kolonRet)</div>
    </div>
  </div>
  <div class="meta">사용자 코오롱티슈진 평가액: $(Format-KRW $kolonValue) (5,290주)</div>
</section>
"@
} else {
    $benchHtml = @"
<section class="card">
  <h2>벤치마크 비교</h2>
  <p class="empty">첫 cycle 실행 후 표시됩니다.</p>
</section>
"@
}

# === 시계열 차트 (3-way, 시작=100 정규화) ===
$chartHtml = ''
if ($historyEntries.Count -ge 2) {
    $w = 1000; $h = 320; $padL = 50; $padR = 16; $padT = 20; $padB = 40
    $plotW = $w - $padL - $padR
    $plotH = $h - $padT - $padB

    # 내 포트는 시작자본(₩100M)을 base로 — cycle 1도 수수료 차감으로 100보다 약간 아래
    $base_my = $startingCapital
    # 외부 벤치마크는 첫 관측가를 base로 (운영 시작 시점 기준)
    $base_kospi = [double]$historyEntries[0].kospi200_price
    $base_kolon = [double]$historyEntries[0].kolon_price

    $myIdx = @(); $kospiIdx = @(); $kolonIdx = @(); $labels = @()
    foreach ($e in $historyEntries) {
        $myIdx += if ($base_my -gt 0) { ([double]$e.my_value_krw / $base_my) * 100 } else { 100 }
        $kospiIdx += if ($base_kospi -gt 0 -and $null -ne $e.kospi200_price) { ([double]$e.kospi200_price / $base_kospi) * 100 } else { 100 }
        $kolonIdx += if ($base_kolon -gt 0 -and $null -ne $e.kolon_price) { ([double]$e.kolon_price / $base_kolon) * 100 } else { 100 }
        $lbl = ''
        if ($null -ne $e.as_of) {
            $dt = [DateTime]::Parse([string]$e.as_of)
            $lbl = $dt.ToString('M/d HH:mm')
        }
        $labels += $lbl
    }

    $allVals = @() + $myIdx + $kospiIdx + $kolonIdx + 100
    $vmax = ($allVals | Measure-Object -Maximum).Maximum
    $vmin = ($allVals | Measure-Object -Minimum).Minimum
    $vrange = $vmax - $vmin
    if ($vrange -lt 1) { $vrange = 1 }
    $vmax = $vmax + $vrange * 0.1
    $vmin = $vmin - $vrange * 0.1
    $vrange = $vmax - $vmin

    $n = $historyEntries.Count
    $xStep = if ($n -gt 1) { $plotW / ($n - 1) } else { 0 }

    $myPts = ''; $kospiPts = ''; $kolonPts = ''
    $myCircles = ''; $kospiCircles = ''; $kolonCircles = ''
    for ($i = 0; $i -lt $n; $i++) {
        $x = $padL + $i * $xStep
        $myY = $padT + ($vmax - $myIdx[$i]) / $vrange * $plotH
        $kospiY = $padT + ($vmax - $kospiIdx[$i]) / $vrange * $plotH
        $kolonY = $padT + ($vmax - $kolonIdx[$i]) / $vrange * $plotH
        $myPts += ('{0:F1},{1:F1} ' -f $x, $myY)
        $kospiPts += ('{0:F1},{1:F1} ' -f $x, $kospiY)
        $kolonPts += ('{0:F1},{1:F1} ' -f $x, $kolonY)
        $myCircles += ("<circle cx='{0:F1}' cy='{1:F1}' r='3' fill='#4ade80'/>" -f $x, $myY)
        $kospiCircles += ("<circle cx='{0:F1}' cy='{1:F1}' r='3' fill='#9ca3af'/>" -f $x, $kospiY)
        $kolonCircles += ("<circle cx='{0:F1}' cy='{1:F1}' r='3' fill='#a78bfa'/>" -f $x, $kolonY)
    }

    # baseline at 100
    $baselineY = $padT + ($vmax - 100) / $vrange * $plotH

    # Y-axis 5 ticks
    $ticks = ''
    for ($t = 0; $t -lt 5; $t++) {
        $tval = $vmin + ($vmax - $vmin) * (4 - $t) / 4
        $ty = $padT + $t / 4 * $plotH
        $ticks += ("<text x='{0}' y='{1:F1}' fill='#7c8593' font-size='11' text-anchor='end'>{2:N1}</text>" -f ($padL - 8), ($ty + 4), $tval)
        $ticks += ("<line x1='{0}' y1='{1:F1}' x2='{2}' y2='{1:F1}' stroke='#1f242e' stroke-dasharray='2 2'/>" -f $padL, $ty, ($w - $padR))
    }

    # X-axis labels (every entry if N<=10, else every Nth)
    $xLabels = ''
    $skipLabel = if ($n -le 10) { 1 } else { [math]::Ceiling($n / 10) }
    for ($i = 0; $i -lt $n; $i++) {
        if ($i % $skipLabel -ne 0 -and $i -ne ($n - 1)) { continue }
        $x = $padL + $i * $xStep
        $xLabels += ("<text x='{0:F1}' y='{1}' fill='#7c8593' font-size='10' text-anchor='middle'>{2}</text>" -f $x, ($h - 18), $labels[$i])
    }

    $lastMy = $myIdx[-1]; $lastKospi = $kospiIdx[-1]; $lastKolon = $kolonIdx[-1]

    $chartHtml = @"
<section class="card">
  <h2>📉 시계열 비교 (시작=100 정규화)</h2>
  <svg viewBox="0 0 $w $h" xmlns="http://www.w3.org/2000/svg" style="width:100%;height:auto;background:#0f1115;border-radius:8px">
    $ticks
    <line x1="$padL" y1="$($baselineY.ToString('F1'))" x2="$($w - $padR)" y2="$($baselineY.ToString('F1'))" stroke="#666" stroke-width="1" stroke-dasharray="4 4"/>
    <text x="$($w - $padR - 4)" y="$(($baselineY - 4).ToString('F1'))" fill="#888" font-size="10" text-anchor="end">baseline 100</text>
    <polyline points="$kospiPts" fill="none" stroke="#9ca3af" stroke-width="2"/>
    $kospiCircles
    <polyline points="$kolonPts" fill="none" stroke="#a78bfa" stroke-width="2"/>
    $kolonCircles
    <polyline points="$myPts" fill="none" stroke="#4ade80" stroke-width="2.5"/>
    $myCircles
    $xLabels
  </svg>
  <div style="display:flex;gap:24px;justify-content:center;margin-top:14px;font-size:13px;flex-wrap:wrap">
    <span><span style="display:inline-block;width:14px;height:3px;background:#4ade80;vertical-align:middle;margin-right:6px"></span>나의 모의 포트 ($('{0:N2}' -f $lastMy))</span>
    <span><span style="display:inline-block;width:14px;height:3px;background:#9ca3af;vertical-align:middle;margin-right:6px"></span>KOSPI 200 ($('{0:N2}' -f $lastKospi))</span>
    <span><span style="display:inline-block;width:14px;height:3px;background:#a78bfa;vertical-align:middle;margin-right:6px"></span>코오롱티슈진 ($('{0:N2}' -f $lastKolon))</span>
  </div>
  <div class="meta">N=$n cycles. 각 cycle 마감 시 portfolio 평가액 / KOSPI 200 종가 / 코오롱티슈진 종가를 시작값으로 나눠 100으로 정규화.</div>
</section>
"@
} else {
    $chartHtml = @"
<section class="card">
  <h2>📉 시계열 비교 (시작=100 정규화)</h2>
  <p class="empty">차트는 cycle 2 이후부터 표시됩니다 (현재 데이터 포인트 $($historyEntries.Count)개).</p>
</section>
"@
}

# 거래 로그 (마지막 N개)
function Get-LastBlocks {
    param([string]$Markdown, [int]$Count)
    if ([string]::IsNullOrWhiteSpace($Markdown)) { return @() }
    # [regex]::Split returns the preamble as element [0]; drop it.
    $parts = [regex]::Split($Markdown, '(?m)^## ')
    if ($parts.Count -le 1) { return @() }
    $blocks = $parts[1..($parts.Count - 1)] |
        Where-Object { $_ -match '\S' } |
        ForEach-Object { '## ' + $_.TrimEnd() }
    if ($blocks.Count -le $Count) { return @($blocks) }
    return @($blocks[-$Count..-1])
}

$recentTradeRows = ''
$recentTrades = $tradesArr | Sort-Object @{e={$_.Date};desc=$true}, @{e={$_.Time};desc=$true} | Select-Object -First 5
foreach ($t in $recentTrades) {
    $typeClass = if ($t.Type -eq 'BUY') { 'buy' } else { 'sell' }
    $typeIcon = if ($t.Type -eq 'BUY') { '▲' } else { '▼' }
    $recentTradeRows += @"
<tr>
  <td><small>$(Encode-Html $t.Date) $(Encode-Html $t.Time)</small></td>
  <td><span class="type-badge $typeClass">$typeIcon $($t.Type)</span></td>
  <td><span class="code">$(Encode-Html $t.Code)</span> $(Encode-Html $t.Name)</td>
  <td class="num">$('{0:N0}' -f $t.Shares)주 @ $(Format-KRW $t.Price)</td>
  <td class="num"><strong>$(Format-KRW $t.Amount)</strong></td>
</tr>
"@
}
$tradeHtml = if ($tradesArr.Count -gt 0) {
    @"
<table style="width:100%;font-size:13px">
  <thead><tr>
    <th>일시</th><th>구분</th><th>종목</th><th class="num">수량 @ 단가</th><th class="num">금액</th>
  </tr></thead>
  <tbody>$recentTradeRows</tbody>
</table>
<div style="margin-top:14px;text-align:center">
  <a href="trades.html" style="color:#4ade80;text-decoration:none;font-size:14px;display:inline-block;padding:10px 20px;background:#1a1e28;border:1px solid #2a2f3a;border-radius:6px">📋 전체 거래 기록 보기 ($totalTrades건) →</a>
</div>
"@
} else {
    '<p class="empty">아직 체결된 거래가 없습니다.</p>'
}

$decBlocks = Get-LastBlocks -Markdown $decisions -Count 5
$decHtml = if ($decBlocks.Count -gt 0) {
    '<pre class="md">' + (Encode-Html ($decBlocks -join "`n`n")) + '</pre>'
} else {
    '<p class="empty">아직 점검 기록이 없습니다.</p>'
}

# === 거래 기록 파싱 (trades.html용) ===
function Parse-Trades {
    param([string]$Markdown)
    $trades = @()
    if ([string]::IsNullOrWhiteSpace($Markdown)) { return $trades }
    $parts = [regex]::Split($Markdown, '(?m)^## ')
    if ($parts.Count -le 1) { return $trades }
    foreach ($block in $parts[1..($parts.Count - 1)]) {
        $block = $block.Trim()
        if ($block -notmatch '^(\d{4}-\d{2}-\d{2})\s+(\d{2}:\d{2})\s+KST\s*\|\s*(BUY|SELL)\s*\|\s*(\d{6})\s+([^\r\n\(]+)') { continue }
        $date = $matches[1]; $time = $matches[2]; $type = $matches[3]; $code = $matches[4]; $name = $matches[5].Trim()
        $shares = 0; $price = 0; $amount = 0; $fee = 0; $reason = ''
        if ($block -match '수량:\s*([0-9,]+)주\s*@\s*₩([0-9,]+)') {
            $shares = [int]([string]$matches[1] -replace ',', '')
            $price = [int]([string]$matches[2] -replace ',', '')
        }
        if ($block -match '체결금액:\s*₩([0-9,]+)') { $amount = [int]([string]$matches[1] -replace ',', '') }
        if ($block -match '수수료:\s*₩([0-9,]+)') { $fee = [int]([string]$matches[1] -replace ',', '') }
        if ($block -match '(?m)^- 사유:\s*(.+?)\s*$') { $reason = $matches[1].Trim() }
        $trades += [PSCustomObject]@{
            Date = $date; Time = $time; Type = $type; Code = $code; Name = $name
            Shares = $shares; Price = $price; Amount = $amount; Fee = $fee; Reason = $reason
        }
    }
    return $trades
}

$tradesArr = @(Parse-Trades -Markdown $tradeLog)
$totalTrades = $tradesArr.Count
$totalBuy = @($tradesArr | Where-Object { $_.Type -eq 'BUY' }).Count
$totalSell = @($tradesArr | Where-Object { $_.Type -eq 'SELL' }).Count
$totalAmount = ($tradesArr | Measure-Object -Sum Amount).Sum
$totalFee = ($tradesArr | Measure-Object -Sum Fee).Sum
if ($null -eq $totalAmount) { $totalAmount = 0 }
if ($null -eq $totalFee) { $totalFee = 0 }

# Build trades.html (separate page)
$tradeRows = ''
foreach ($t in ($tradesArr | Sort-Object @{e={$_.Date};desc=$true}, @{e={$_.Time};desc=$true})) {
    $typeClass = if ($t.Type -eq 'BUY') { 'buy' } else { 'sell' }
    $typeIcon = if ($t.Type -eq 'BUY') { '▲ 매수' } else { '▼ 매도' }
    $tradeRows += @"
<tr class="trade-row $typeClass" data-type="$($t.Type)">
  <td class="num">$(Encode-Html $t.Date)<br><small>$(Encode-Html $t.Time) KST</small></td>
  <td><span class="type-badge $typeClass">$typeIcon</span></td>
  <td><span class="code">$(Encode-Html $t.Code)</span></td>
  <td>$(Encode-Html $t.Name)</td>
  <td class="num">$('{0:N0}' -f $t.Shares)</td>
  <td class="num">$(Format-KRW $t.Price)</td>
  <td class="num"><strong>$(Format-KRW $t.Amount)</strong></td>
  <td class="num">$(Format-KRW $t.Fee)</td>
  <td class="reason-cell">$(Encode-Html $t.Reason)</td>
</tr>
"@
}

$tradesHtml = @"
<!DOCTYPE html>
<html lang="ko">
<head>
<meta charset="UTF-8">
<title>거래 기록 — Korean Stock Mock Portfolio</title>
<style>
  * { box-sizing: border-box; }
  body { font-family: -apple-system, 'Segoe UI', 'Malgun Gothic', sans-serif; background: #0f1115; color: #e6e8eb; margin: 0; padding: 24px; line-height: 1.5; }
  h1 { margin: 0 0 4px 0; font-size: 28px; }
  .container { max-width: 1400px; margin: 0 auto; }
  .header-meta { color: #7c8593; font-size: 13px; margin-bottom: 24px; }
  .card { background: #161922; border: 1px solid #2a2f3a; border-radius: 12px; padding: 24px; margin-bottom: 20px; }
  .back-link { display: inline-block; color: #4ade80; text-decoration: none; margin-bottom: 16px; font-size: 14px; }
  .back-link:hover { text-decoration: underline; }
  .stats { display: grid; grid-template-columns: repeat(4, 1fr); gap: 16px; }
  .stats > div { background: #0f1115; border: 1px solid #2a2f3a; border-radius: 8px; padding: 16px; }
  .stats label { color: #7c8593; font-size: 12px; display: block; }
  .stats .val { font-size: 24px; font-weight: 700; margin-top: 4px; }
  .filter-bar { display: flex; gap: 8px; margin-bottom: 16px; }
  .filter-btn { background: #2a2f3a; color: #b9c1cc; border: none; padding: 8px 16px; border-radius: 6px; cursor: pointer; font-size: 13px; }
  .filter-btn.active { background: #4ade80; color: #0f1115; }
  table { width: 100%; border-collapse: collapse; font-size: 13px; }
  th { text-align: left; padding: 10px 12px; color: #b9c1cc; font-weight: 600; font-size: 12px; border-bottom: 2px solid #2a2f3a; background: #1a1e28; position: sticky; top: 0; }
  td { padding: 12px; border-bottom: 1px solid #1f242e; vertical-align: top; }
  tr.trade-row.buy { background: rgba(74, 222, 128, 0.04); }
  tr.trade-row.sell { background: rgba(248, 113, 113, 0.04); }
  tr.trade-row:hover { background: #1a1e28; }
  .num { text-align: right; font-variant-numeric: tabular-nums; white-space: nowrap; }
  .code { font-family: 'Consolas', monospace; background: #2a2f3a; padding: 2px 6px; border-radius: 4px; font-size: 12px; }
  .type-badge { display: inline-block; padding: 4px 10px; border-radius: 4px; font-size: 12px; font-weight: 600; }
  .type-badge.buy { background: #166534; color: #4ade80; }
  .type-badge.sell { background: #991b1b; color: #f87171; }
  .reason-cell { color: #b9c1cc; max-width: 380px; line-height: 1.4; }
  small { font-size: 11px; color: #7c8593; }
  .empty { color: #7c8593; font-style: italic; padding: 32px; text-align: center; }
</style>
</head>
<body>
<div class="container">
  <a href="dashboard.html" class="back-link">← 대시보드로 돌아가기</a>
  <h1>📋 전체 거래 기록</h1>
  <div class="header-meta">한국 주식 모의 포트폴리오 — 2026-05-06 ~ 운영 중</div>

  <section class="card">
    <div class="stats">
      <div><label>총 거래 건수</label><div class="val">$totalTrades</div><small>매수 $totalBuy · 매도 $totalSell</small></div>
      <div><label>총 거래대금</label><div class="val">$(Format-KRW $totalAmount)</div></div>
      <div><label>누적 수수료/세금</label><div class="val">$(Format-KRW $totalFee)</div></div>
      <div><label>실현 손익</label><div class="val $(Get-PnlClass $realizedPnl)">$(Format-KRW $realizedPnl)</div></div>
    </div>
  </section>

  <section class="card">
    <div class="filter-bar">
      <button class="filter-btn active" onclick="filt(this,'all')">전체</button>
      <button class="filter-btn" onclick="filt(this,'BUY')">매수만</button>
      <button class="filter-btn" onclick="filt(this,'SELL')">매도만</button>
    </div>
    <table>
      <thead><tr>
        <th>일시 (KST)</th>
        <th>구분</th>
        <th>코드</th>
        <th>종목명</th>
        <th class="num">수량</th>
        <th class="num">단가</th>
        <th class="num">체결금액</th>
        <th class="num">수수료</th>
        <th>사유</th>
      </tr></thead>
      <tbody id="tbody">
        $(if ($tradesArr.Count -gt 0) { $tradeRows } else { '<tr><td colspan="9" class="empty">아직 체결된 거래가 없습니다.</td></tr>' })
      </tbody>
    </table>
  </section>
</div>
<script>
function filt(btn, type) {
  document.querySelectorAll('.filter-btn').forEach(b => b.classList.remove('active'));
  btn.classList.add('active');
  document.querySelectorAll('.trade-row').forEach(r => {
    r.style.display = (type === 'all' || r.dataset.type === type) ? '' : 'none';
  });
}
</script>
</body>
</html>
"@

$tradesPath = Join-Path $PSScriptRoot 'trades.html'
$utf8NoBom = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllText($tradesPath, $tradesHtml, $utf8NoBom)

# === 최종 HTML ===
$generated = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')

$html = @"
<!DOCTYPE html>
<html lang="ko">
<head>
<meta charset="UTF-8">
<title>Korean Stock Mock Portfolio</title>
<style>
  * { box-sizing: border-box; }
  body { font-family: -apple-system, 'Segoe UI', 'Malgun Gothic', sans-serif; background: #0f1115; color: #e6e8eb; margin: 0; padding: 24px; line-height: 1.5; }
  h1 { margin: 0 0 4px 0; font-size: 28px; }
  h2 { margin: 0 0 16px 0; font-size: 18px; color: #b9c1cc; border-bottom: 1px solid #2a2f3a; padding-bottom: 8px; }
  .container { max-width: 1200px; margin: 0 auto; }
  .header-meta { color: #7c8593; font-size: 13px; margin-bottom: 24px; }
  .card { background: #161922; border: 1px solid #2a2f3a; border-radius: 12px; padding: 24px; margin-bottom: 20px; }
  .summary .hdr { color: #7c8593; font-size: 13px; text-transform: uppercase; letter-spacing: 0.5px; }
  .summary .big { font-size: 42px; font-weight: 700; margin: 4px 0; }
  .summary .sub { font-size: 16px; margin-bottom: 20px; }
  .grid4 { display: grid; grid-template-columns: repeat(4, 1fr); gap: 16px; padding-top: 16px; border-top: 1px solid #2a2f3a; }
  .grid4 > div { display: flex; flex-direction: column; }
  .grid4 label { color: #7c8593; font-size: 12px; }
  .grid4 span { font-size: 18px; font-weight: 600; }
  .meta { color: #7c8593; font-size: 12px; margin-top: 16px; }
  table { width: 100%; border-collapse: collapse; }
  th { text-align: left; padding: 10px 12px; color: #b9c1cc; font-weight: 600; font-size: 13px; border-bottom: 2px solid #2a2f3a; }
  td { padding: 12px; border-bottom: 1px solid #1f242e; vertical-align: middle; }
  tr:hover { background: #1a1e28; }
  .num { text-align: right; font-variant-numeric: tabular-nums; }
  .code { font-family: 'Consolas', monospace; background: #2a2f3a; padding: 2px 6px; border-radius: 4px; font-size: 12px; }
  .bucket { background: #2a2f3a; padding: 2px 8px; border-radius: 10px; font-size: 11px; color: #b9c1cc; }
  .pos { color: #4ade80; }
  .neg { color: #f87171; }
  .zero { color: #b9c1cc; }
  .empty { color: #7c8593; font-style: italic; padding: 16px; text-align: center; }
  small { font-size: 11px; color: #7c8593; }
  .bench { display: flex; flex-direction: column; gap: 14px; }
  .bench-row { display: grid; grid-template-columns: 220px 1fr 100px; gap: 12px; align-items: center; }
  .bench-label { font-size: 14px; }
  .bench-bar { background: #1f242e; border-radius: 6px; height: 24px; overflow: hidden; }
  .bar { height: 100%; border-radius: 6px; transition: width 0.3s; }
  .bar.pos { background: linear-gradient(90deg, #166534, #4ade80); }
  .bar.neg { background: linear-gradient(90deg, #991b1b, #f87171); }
  .bar.zero { background: #2a2f3a; }
  .bench-val { text-align: right; font-weight: 600; font-size: 16px; }
  pre.md { background: #0f1115; border: 1px solid #2a2f3a; border-radius: 8px; padding: 16px; overflow-x: auto; font-size: 12px; line-height: 1.5; white-space: pre-wrap; word-wrap: break-word; }
  .type-badge { display: inline-block; padding: 3px 8px; border-radius: 4px; font-size: 11px; font-weight: 600; }
  .type-badge.buy { background: #166534; color: #4ade80; }
  .type-badge.sell { background: #991b1b; color: #f87171; }
  .footer { color: #7c8593; font-size: 11px; text-align: center; margin-top: 32px; padding-top: 16px; border-top: 1px solid #2a2f3a; }
</style>
</head>
<body>
<div class="container">
  <h1>📈 한국 주식 모의 포트폴리오</h1>
  <div class="header-meta">시작금 ₩100,000,000 · 운영기간 2026-05-06 ~ ~2026-06-05 · 하루 3회 자동 점검</div>

  $summaryHtml
  $benchHtml
  $chartHtml
  $positionsHtml

  <section class="card">
    <h2>최근 거래 (최대 10건)</h2>
    $tradeHtml
  </section>

  <section class="card">
    <h2>최근 점검 기록 (최대 5회)</h2>
    $decHtml
  </section>

  <div class="footer">
    Dashboard 생성 시각: $generated · 이 페이지는 정적 HTML입니다. 다시 보려면 view.bat을 더블클릭하세요.
  </div>
</div>
</body>
</html>
"@

$utf8NoBom = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllText($OutHtml, $html, $utf8NoBom)

Write-Host ('Dashboard 생성: ' + $OutHtml) -ForegroundColor Green
Start-Process $OutHtml
