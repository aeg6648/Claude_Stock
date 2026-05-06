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

$tradeBlocks = Get-LastBlocks -Markdown $tradeLog -Count 10
$tradeHtml = if ($tradeBlocks.Count -gt 0) {
    '<pre class="md">' + (Encode-Html ($tradeBlocks -join "`n`n")) + '</pre>'
} else {
    '<p class="empty">아직 체결된 거래가 없습니다.</p>'
}

$decBlocks = Get-LastBlocks -Markdown $decisions -Count 5
$decHtml = if ($decBlocks.Count -gt 0) {
    '<pre class="md">' + (Encode-Html ($decBlocks -join "`n`n")) + '</pre>'
} else {
    '<p class="empty">아직 점검 기록이 없습니다.</p>'
}

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
  .footer { color: #7c8593; font-size: 11px; text-align: center; margin-top: 32px; padding-top: 16px; border-top: 1px solid #2a2f3a; }
</style>
</head>
<body>
<div class="container">
  <h1>📈 한국 주식 모의 포트폴리오</h1>
  <div class="header-meta">시작금 ₩100,000,000 · 운영기간 2026-05-06 ~ ~2026-06-05 · 하루 3회 자동 점검</div>

  $summaryHtml
  $benchHtml
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
