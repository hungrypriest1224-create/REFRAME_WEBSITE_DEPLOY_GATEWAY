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

function Invoke-VersionUpload {
  param([string]$WorkerName)
  $output = & npx --yes wrangler@4.145.0 versions upload --config wrangler.jsonc --name $WorkerName --message "RE:FRAME Drive source $env:SOURCE_FINGERPRINT" --yes 2>&1
  $code = $LASTEXITCODE
  return [pscustomobject]@{
    Output = $output
    ExitCode = $code
    Text = (($output | ForEach-Object { $_.ToString() }) -join "`n")
  }
}

Push-Location -LiteralPath $sourceRoot
try {
  $config = Get-Content -LiteralPath "wrangler.jsonc" -Raw | ConvertFrom-Json
  $workerName = [string]$config.name
  if (-not $workerName) { throw "Worker name is missing from wrangler.jsonc." }

  # Upload code/assets/bindings as a Worker Version without changing routes or
  # custom domains. If a prior Dashboard rollback makes Wrangler insist on
  # reading route/domain metadata that this intentionally-scoped token cannot
  # read, first replace only the Worker script content through the API. That
  # bootstrap endpoint leaves config, bindings, assets, routes, domains and
  # secrets untouched, then Wrangler can resume normal API-managed uploads.
  $upload = Invoke-VersionUpload -WorkerName $workerName
  $upload.Output | ForEach-Object { Write-Output $_ }

  if ($upload.ExitCode -ne 0 -and $upload.Text -match "Unable to fetch bindings, routes, or services metadata from the dashboard") {
    Write-Warning "Wrangler detected a Dashboard-managed Worker version. Applying a code-only API bootstrap that preserves all existing configuration, then retrying the normal version upload."
    node (Join-Path $PSScriptRoot "bootstrap-worker-content.mjs")
    if ($LASTEXITCODE -ne 0) { throw "Code-only Worker bootstrap failed." }

    $upload = Invoke-VersionUpload -WorkerName $workerName
    $upload.Output | ForEach-Object { Write-Output $_ }
  }

  if ($upload.ExitCode -ne 0) {
    throw "Cloudflare Worker Version upload failed with exit code $($upload.ExitCode)."
  }

  $versionMatch = [regex]::Match($upload.Text, "Worker Version ID:\s*([0-9a-fA-F-]{36})")
  if (-not $versionMatch.Success) {
    throw "Wrangler did not report a Worker Version ID."
  }
  $versionId = $versionMatch.Groups[1].Value

  $previewMatch = [regex]::Match($upload.Text, "Version Preview URL:\s*(https://[^\s]+)")
  if ($previewMatch.Success) {
    $candidateOrigin = $previewMatch.Groups[1].Value.TrimEnd("/")
    node scripts/verify-live.mjs $candidateOrigin
    if ($LASTEXITCODE -ne 0) { throw "Candidate Worker Version verification failed for $candidateOrigin." }
  } else {
    Write-Warning "Wrangler did not report a Version Preview URL; continuing with the uploaded version ID."
  }

  $versionSpec = "${versionId}@100%"
  $deployOutput = & npx --yes wrangler@4.145.0 versions deploy $versionSpec --name $workerName --yes 2>&1
  $deployExitCode = $LASTEXITCODE
  $deployOutput | ForEach-Object { Write-Output $_ }
  if ($deployExitCode -ne 0) {
    throw "Cloudflare Worker Version deployment failed with exit code $deployExitCode."
  }

  if (-not $expectedOrigin) {
    throw "A fixed workers.dev verification origin is required."
  }
  $origin = $expectedOrigin

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
    "- Worker Version upload and 100% deployment: passed.",
    "- Existing routes and custom domains: left unchanged.",
    "- Live consultation routes, draft robots policy, public assets, and unauthenticated KFB routes: passed.",
    "- Worker Version ID: $versionId",
    "- Preview URL: $origin",
    "- Public URL: $publicOrigin",
    "- Source fingerprint: $env:SOURCE_FINGERPRINT"
  ) -join "`n"
  if ($env:GITHUB_STEP_SUMMARY) { Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value $summary }
}
finally {
  Pop-Location
}
