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

Push-Location -LiteralPath $sourceRoot
try {
  $config = Get-Content -LiteralPath "wrangler.jsonc" -Raw | ConvertFrom-Json
  $workerName = [string]$config.name
  if (-not $workerName) { throw "Worker name is missing from wrangler.jsonc." }

  # Upload code/assets/bindings as a Worker Version first. This intentionally does
  # not modify existing routes or custom domains, so the Gateway only needs Editor
  # access to the existing Worker.
  $uploadOutput = & npx --yes wrangler@4.144.0 versions upload --config wrangler.jsonc --message "RE:FRAME Drive source $env:SOURCE_FINGERPRINT" 2>&1
  $uploadExitCode = $LASTEXITCODE
  $uploadOutput | ForEach-Object { Write-Output $_ }
  if ($uploadExitCode -ne 0) {
    throw "Cloudflare Worker Version upload failed with exit code $uploadExitCode."
  }

  $uploadText = ($uploadOutput | ForEach-Object { $_.ToString() }) -join "`n"
  $versionMatch = [regex]::Match($uploadText, "Worker Version ID:\s*([0-9a-fA-F-]{36})")
  if (-not $versionMatch.Success) {
    throw "Wrangler did not report a Worker Version ID."
  }
  $versionId = $versionMatch.Groups[1].Value

  $previewMatch = [regex]::Match($uploadText, "Version Preview URL:\s*(https://[^\s]+)")
  if ($previewMatch.Success) {
    $candidateOrigin = $previewMatch.Groups[1].Value.TrimEnd("/")
    node scripts/verify-live.mjs $candidateOrigin
    if ($LASTEXITCODE -ne 0) { throw "Candidate Worker Version verification failed for $candidateOrigin." }
  } else {
    Write-Warning "Wrangler did not report a Version Preview URL; continuing with the uploaded version ID."
  }

  $versionSpec = "${versionId}@100%"
  $deployOutput = & npx --yes wrangler@4.144.0 versions deploy $versionSpec --name $workerName --yes 2>&1
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
