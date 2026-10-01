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

$publicOrigin = ""
if ($env:PUBLIC_ORIGIN) {
  $publicOrigin = $env:PUBLIC_ORIGIN.TrimEnd("/")
  $parsedPublicOrigin = $null
  try { $parsedPublicOrigin = [Uri]$publicOrigin } catch { throw "PUBLIC_ORIGIN is not a valid URL." }
  if ($parsedPublicOrigin.Scheme -ne "https") {
    throw "PUBLIC_ORIGIN must be an HTTPS origin."
  }
}

function Write-WorkerMetadataProbe {
  if (-not $env:CLOUDFLARE_ACCOUNT_ID -or -not $env:CLOUDFLARE_API_TOKEN) {
    Write-Output "Read-only Worker metadata probe skipped: Cloudflare credentials are not configured."
    return
  }

  try {
    $workerName = [string](Get-Content -LiteralPath (Join-Path $sourceRoot "wrangler.jsonc") -Raw | ConvertFrom-Json).name
    if (-not $workerName) { throw "Worker name is missing." }
  } catch {
    Write-Output "Read-only Worker metadata probe skipped: Worker name could not be read from wrangler.jsonc."
    return
  }

  $workerName = [Uri]::EscapeDataString($workerName)
  $environment = "production"
  $accountPath = "/accounts/$($env:CLOUDFLARE_ACCOUNT_ID)"
  $paths = @(
    "${accountPath}/workers/services/${workerName}/environments/${environment}/bindings",
    "${accountPath}/workers/services/${workerName}/environments/${environment}/routes?show_zonename=true",
    "${accountPath}/workers/domains/records?page=0&per_page=5&service=${workerName}&environment=${environment}",
    "${accountPath}/workers/services/${workerName}/environments/${environment}/subdomain",
    "${accountPath}/workers/services/${workerName}/environments/${environment}",
    "${accountPath}/workers/scripts/${workerName}/schedules"
  )

  $client = [System.Net.Http.HttpClient]::new()
  try {
    $client.Timeout = [TimeSpan]::FromSeconds(10)
    $client.DefaultRequestHeaders.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new("Bearer", $env:CLOUDFLARE_API_TOKEN)
    foreach ($path in $paths) {
      $response = $null
      $safePath = $path.Replace($env:CLOUDFLARE_ACCOUNT_ID, "{account_id}")
      try {
        $response = $client.GetAsync("https://api.cloudflare.com/client/v4$path").GetAwaiter().GetResult()
        Write-Output "Read-only Worker metadata probe: GET $safePath -> HTTP $([int]$response.StatusCode)"
      } catch {
        Write-Output "Read-only Worker metadata probe: GET $safePath -> transport error ($($_.Exception.GetType().Name))"
      } finally {
        if ($response) { $response.Dispose() }
      }
    }
  } finally {
    $client.Dispose()
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
    $dashboardMetadataLookupFailure = $outputText -match "Unable to fetch bindings, routes, or services metadata from the dashboard"
    $scopedTokenSubdomainLookupFailure =
      ($outputText -match "/workers/subdomain") -and
      ($outputText -match "Authentication error\s+\[code:\s*10000\]")

    if ($dashboardMetadataLookupFailure -and -not $uploadCompleted) {
      Write-WorkerMetadataProbe
    }

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

  if ($publicOrigin) {
    node scripts/verify-live.mjs $publicOrigin
    if ($LASTEXITCODE -ne 0) { throw "Live public-domain verification failed for $publicOrigin." }
  }

  $summary = @(
    "## RE:FRAME deployment verified",
    "",
    "- Temporary Drive snapshot: fetched and checked for changes during download.",
    "- Build and KFB auth tests: passed.",
    "- Live consultation routes, draft robots policy, public assets, and unauthenticated KFB routes: passed.",
    "- Preview URL: $origin",
    "- Public URL: $publicOrigin",
    "- Source fingerprint: $env:SOURCE_FINGERPRINT"
  ) -join "`n"
  if ($env:GITHUB_STEP_SUMMARY) { Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value $summary }
}
finally {
  Pop-Location
}
