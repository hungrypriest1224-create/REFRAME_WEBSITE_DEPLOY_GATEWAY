$ErrorActionPreference = "Stop"
$sourceRoot = [IO.Path]::GetFullPath($env:SNAPSHOT_DIR)
$runnerTemp = [IO.Path]::GetFullPath($env:RUNNER_TEMP).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
if (-not $sourceRoot.StartsWith($runnerTemp, [StringComparison]::OrdinalIgnoreCase)) {
  throw "Source snapshot is outside the runner temporary directory."
}
if (-not $env:CLOUDFLARE_ACCOUNT_ID -or -not $env:CLOUDFLARE_API_TOKEN) {
  throw "Cloudflare deployment credentials are not configured."
}

Push-Location -LiteralPath $sourceRoot
try {
  $deployOutput = & npx --yes wrangler@4.129.1 deploy --config wrangler.jsonc 2>&1
  $deployExitCode = $LASTEXITCODE
  $deployOutput | ForEach-Object { Write-Output $_ }
  if ($deployExitCode -ne 0) { throw "Cloudflare deployment failed with exit code $deployExitCode." }

  $outputText = ($deployOutput | ForEach-Object { $_.ToString() }) -join "`n"
  $originMatch = [regex]::Match($outputText, "https://[a-zA-Z0-9-]+(?:\.[a-zA-Z0-9-]+)*\.workers\.dev")
  if (-not $originMatch.Success) { throw "Wrangler did not report the workers.dev URL; live verification was not possible." }

  $origin = $originMatch.Value
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

