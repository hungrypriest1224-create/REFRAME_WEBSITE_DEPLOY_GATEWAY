$ErrorActionPreference = "Stop"
$sourceRoot = [IO.Path]::GetFullPath($env:SNAPSHOT_DIR)
$runnerTemp = [IO.Path]::GetFullPath($env:RUNNER_TEMP).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
if (-not $sourceRoot.StartsWith($runnerTemp, [StringComparison]::OrdinalIgnoreCase)) {
  throw "Source snapshot is outside the runner temporary directory."
}
if (-not $env:CLOUDFLARE_ACCOUNT_ID -or -not $env:CLOUDFLARE_API_TOKEN) {
  throw "Cloudflare deployment credentials are not configured."
}

$expectedOrigin = ""
if ($env:WORKER_ORIGIN) {
  $expectedOrigin = $env:WORKER_ORIGIN.TrimEnd("/")
  $parsedOrigin = $null
  try { $parsedOrigin = [Uri]$expectedOrigin } catch { throw "WORKER_ORIGIN is not a valid URL." }
  if ($parsedOrigin.Scheme -ne "https" -or -not $parsedOrigin.Host.EndsWith(".workers.dev", [StringComparison]::OrdinalIgnoreCase)) {
    throw "WORKER_ORIGIN must be an HTTPS workers.dev origin."
  }
}

Push-Location -LiteralPath $sourceRoot
try {
  $deployOutput = & npx --yes wrangler@4.129.1 deploy --config wrangler.jsonc 2>&1
  $deployExitCode = $LASTEXITCODE
  $deployOutput | ForEach-Object { Write-Output $_ }
  $outputText = ($deployOutput | ForEach-Object { $_.ToString() }) -join "`n"

  if ($deployExitCode -ne 0) {
    $uploadCompleted = $outputText -match "(?m)^Uploaded\s+reframe-web\s+\("
    $scopedTokenSubdomainLookupFailure =
      ($outputText -match "/workers/subdomain") -and
      ($outputText -match "Authentication error\s+\[code:\s*10000\]")

    if (-not ($uploadCompleted -and $scopedTokenSubdomainLookupFailure -and $expectedOrigin)) {
      throw "Cloudflare deployment failed with exit code $deployExitCode."
    }

    Write-Warning "Wrangler uploaded reframe-web, then its account-level workers.dev subdomain lookup was blocked by the Worker-scoped token. Continuing only to live verification of the fixed workers.dev origin."
  }

  $reportedOriginMatch = [regex]::Match($outputText, "https://[a-zA-Z0-9-]+(?:\.[a-zA-Z0-9-]+)*\.workers\.dev")
  if ($expectedOrigin) {
    if ($reportedOriginMatch.Success -and $reportedOriginMatch.Value.TrimEnd("/") -ne $expectedOrigin) {
      throw "Wrangler reported an unexpected workers.dev origin: $($reportedOriginMatch.Value)"
    }
    $origin = $expectedOrigin
  }
  elseif ($reportedOriginMatch.Success) {
    $origin = $reportedOriginMatch.Value
  }
  else {
    throw "Wrangler did not report the workers.dev URL and no fixed verification origin is configured."
  }

  node scripts/verify-live.mjs $origin
  if ($LASTEXITCODE -ne 0) { throw "Live Worker verification failed for $origin." }

  $summary = @(
    "## RE:FRAME deployment verified",
    "",
    "- Temporary Drive snapshot: fetched and checked for changes during download.",
    "- Build and KFB auth tests: passed.",
    "- Live public pages, draft robots policy, and unauthenticated KFB routes: passed.",
    "- Preview URL: $origin",
    "- Source fingerprint: $env:SOURCE_FINGERPRINT"
  ) -join "`n"
  if ($env:GITHUB_STEP_SUMMARY) { Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value $summary }
}
finally {
  Pop-Location
}
