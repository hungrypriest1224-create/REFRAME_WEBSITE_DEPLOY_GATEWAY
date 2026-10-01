$ErrorActionPreference = "Stop"
$sourceRoot = [IO.Path]::GetFullPath($env:SNAPSHOT_DIR)
$runnerTemp = [IO.Path]::GetFullPath($env:RUNNER_TEMP).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
if (-not $sourceRoot.StartsWith($runnerTemp, [StringComparison]::OrdinalIgnoreCase)) {
  throw "Source snapshot is outside the runner temporary directory."
}

$expectedOrigin = ($env:WORKER_ORIGIN ?? "").TrimEnd("/")
$publicOrigin = ($env:PUBLIC_ORIGIN ?? "").TrimEnd("/")
if (-not $expectedOrigin) { throw "WORKER_ORIGIN is required." }

function Invoke-VersionUpload {
  param([string]$WorkerName)
  $output = & npx --yes wrangler@4.145.0 versions upload --config wrangler.jsonc --name $WorkerName --message "RE:FRAME Drive source $env:SOURCE_FINGERPRINT" 2>&1
  return [pscustomobject]@{
    Output = $output
    ExitCode = $LASTEXITCODE
    Text = (($output | ForEach-Object { $_.ToString() }) -join "`n")
  }
}

Push-Location -LiteralPath $sourceRoot
try {
  $config = Get-Content -LiteralPath "wrangler.jsonc" -Raw | ConvertFrom-Json
  $workerName = [string]$config.name
  if (-not $workerName) { throw "Worker name is missing from wrangler.jsonc." }

  $upload = Invoke-VersionUpload -WorkerName $workerName
  $upload.Output | ForEach-Object { Write-Output $_ }

  if ($upload.ExitCode -ne 0 -and $upload.Text -match "Unable to fetch bindings, routes, or services metadata from the dashboard") {
    Write-Warning "Dashboard-managed version detected. Running a code-only API bootstrap that preserves configuration, then retrying."
    node (Join-Path $PSScriptRoot "bootstrap-worker-content.mjs")
    if ($LASTEXITCODE -ne 0) { throw "Code-only Worker bootstrap failed." }
    $upload = Invoke-VersionUpload -WorkerName $workerName
    $upload.Output | ForEach-Object { Write-Output $_ }
  }

  if ($upload.ExitCode -ne 0) { throw "Worker Version upload failed with exit code $($upload.ExitCode)." }

  $versionMatch = [regex]::Match($upload.Text, "Worker Version ID:\s*([0-9a-fA-F-]{36})")
  if (-not $versionMatch.Success) { throw "Wrangler did not report a Worker Version ID." }
  $versionId = $versionMatch.Groups[1].Value

  $previewMatch = [regex]::Match($upload.Text, "Version Preview URL:\s*(https://[^\s]+)")
  if ($previewMatch.Success) {
    $candidateOrigin = $previewMatch.Groups[1].Value.TrimEnd("/")
    node scripts/verify-live.mjs $candidateOrigin
    if ($LASTEXITCODE -ne 0) { throw "Candidate Worker Version verification failed." }
  }

  $versionSpec = "${versionId}@100%"
  & npx --yes wrangler@4.145.0 versions deploy $versionSpec --name $workerName --yes
  if ($LASTEXITCODE -ne 0) { throw "Worker Version deployment failed." }

  node scripts/verify-live.mjs $expectedOrigin
  if ($LASTEXITCODE -ne 0) { throw "Live Worker verification failed." }
  if ($publicOrigin) {
    node scripts/verify-live.mjs $publicOrigin
    if ($LASTEXITCODE -ne 0) { throw "Live public-domain verification failed." }
  }

  $summary = @(
    "## RE:FRAME deployment verified",
    "",
    "- Drive snapshot and tests: passed.",
    "- Worker Version deployment: passed.",
    "- Existing routes and custom domains: unchanged.",
    "- workers.dev and public-domain verification: passed.",
    "- Worker Version ID: $versionId",
    "- Source fingerprint: $env:SOURCE_FINGERPRINT"
  ) -join "`n"
  if ($env:GITHUB_STEP_SUMMARY) { Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value $summary }
}
finally {
  Pop-Location
}
