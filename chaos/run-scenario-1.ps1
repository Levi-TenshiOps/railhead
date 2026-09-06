<#
.SYNOPSIS
Renders scenario 1's NetworkChaos manifest against a live railhead-api pod.

.DESCRIPTION
Scenario 1 targets ONE api pod by name, and pod names change on every
rebuild. This resolves the name, substitutes it into the template, writes a
rendered manifest, and prints it. It applies nothing unless -Apply is given.

Why a script rather than a hand-edited placeholder: an unedited or mistyped
placeholder does not fail loudly. selector.pods naming a pod that does not
exist yields an experiment that is accepted and injects nothing, which looks
identical to a fault that produced no effect -- the exact ambiguity this
whole session is trying to avoid.

.EXAMPLE
  .\chaos\run-scenario-1.ps1
  .\chaos\run-scenario-1.ps1 -Apply
#>
[CmdletBinding()]
param(
    [switch]$Apply,
    [string]$Namespace = "railhead",
    [string]$Template  = "chaos/experiments/01-networkchaos-api-postgres-partition.yaml",
    [string]$OutFile   = "chaos/experiments/.rendered-01.yaml"
)

# NOTE: $ErrorActionPreference governs CMDLET errors only. It does NOT stop the
# script when a native executable (kubectl, terraform, aws) exits non-zero --
# PowerShell 5.1 has no equivalent of 7.3's $PSNativeCommandUseErrorActionPreference.
# Every kubectl call below therefore checks $LASTEXITCODE explicitly. Skipping
# that is how a failed injection reads as a successful one (known-gotchas #38).
$ErrorActionPreference = "Stop"
$template = $Template

if (-not (Test-Path $template)) { throw "Template not found: $template. Run from the repo root." }

# -o jsonpath with embedded quotes is mangled by PowerShell (known-gotchas
# #20), so go through JSON and let PowerShell do the parsing instead.
$podsJson = kubectl -n $Namespace get pods -l app=railhead-api -o json
if ($LASTEXITCODE -ne 0) {
    throw "kubectl get pods failed (exit $LASTEXITCODE). Fix the cluster connection first -- without this check the script would instead report 'found 0 ready pods' and send you looking at pod health."
}
$pods = $podsJson | ConvertFrom-Json

# @() around the INNER pipeline is load-bearing, not style. In PowerShell 5.1
# a pipeline that emits exactly one object has no .Count at all -- it returns
# empty, and `$null -gt 0` is false -- so an unwrapped
# ($x | Where-Object {...}).Count reports every single-container pod as not
# ready. This filter silently found 0 of 2 healthy pods on its first real run.
# Counting the NOT-ready containers is also the stricter test: it requires
# every container in the pod to be ready, not merely one of them.
$ready = @($pods.items | Where-Object {
    $_.status.phase -eq "Running" -and
    @($_.status.containerStatuses | Where-Object { -not $_.ready }).Count -eq 0
})

if ($ready.Count -lt 2) {
    throw "Need 2 ready railhead-api pods, found $($ready.Count). Scenario 1 requires a healthy sibling: the remediator refuses to quarantine if doing so would leave nothing serving traffic."
}

# Any ready pod is a valid target, so the first two in API order are taken
# deliberately rather than chosen. Both names are printed below so the run is
# reproducible from its own output.
$target  = $ready[0].metadata.name
$sibling = $ready[1].metadata.name

Write-Host ""
Write-Host "  TARGET  (will be partitioned): $target"
Write-Host "  SIBLING (must stay healthy):   $sibling"
Write-Host ""

(Get-Content $template -Raw).Replace("__POD_NAME__", $target) |
    Set-Content $OutFile -Encoding ascii

# ascii, not utf8: PowerShell 5.1 writes a BOM with -Encoding utf8, which has
# already broken one YAML consumer in this project (known-gotchas #5, #16).

Write-Host "Rendered -> $OutFile"
Write-Host ("-" * 60)
Get-Content $OutFile | Where-Object { $_ -notmatch '^\s*#' -and $_.Trim() -ne "" }
Write-Host ("-" * 60)

if ($Apply) {
    Write-Host ""
    Write-Host "Applying..."
    kubectl apply -f $OutFile
    if ($LASTEXITCODE -ne 0) {
        throw "kubectl apply failed (exit $LASTEXITCODE). Nothing was injected. An x509 or webhook error here means gotcha #29 is unsettled -- stop and report rather than re-running."
    }
    Write-Host ""
    Write-Host "Watch the target pod's own metrics FIRST (runbook step 2.2):"
    Write-Host "  kubectl -n $Namespace exec $target -- python -c ""import urllib.request as u; print([l for l in u.urlopen('http://127.0.0.1:8000/metrics').read().decode().splitlines() if 'http_requests_total' in l and '/items' in l])"""
} else {
    Write-Host ""
    Write-Host "Nothing applied. To inject:  kubectl apply -f $OutFile"
    Write-Host "                        or:  .\chaos\run-scenario-1.ps1 -Apply"
}
