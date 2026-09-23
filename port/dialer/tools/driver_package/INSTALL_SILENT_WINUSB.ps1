<#
.SYNOPSIS
    Automated, 100% Silent WinUSB Driver Installer for TP-Link Bluetooth 5.4 Adapter.
    Uses a digitally signed driver package and Windows SetupAPI (pnputil), then
    FORCES the device onto WinUSB. Zero BSOD risk (user-mode driver only).

.DESCRIPTION
    A fresh machine auto-binds the TP-Link UB500 to Microsoft's in-box Bluetooth
    driver (BTHUSB). `pnputil /add-driver /install` only STAGES our WinUSB package
    into the driver store and makes it *available* - it does NOT evict an already
    working, higher-ranked in-box driver. So on a new PC the device stayed on
    BTHUSB, BTstack could never claim the radio over WinUSB, the controller never
    powered on, and discovery found no phones (the exact "Service: BTHUSB" the old
    verify block printed while still saying "DEVICE READY").

    This version does three things the old one did not:
      1. Stages the signed package (as before).
      2. FORCES the binding: assigns our OEM inf to the device with
         `pnputil /add-driver ... /install` scoped at the device, and if the
         device is still not on WinUSB, writes the WinUSB service binding
         directly onto the device's registry Enum key (the same direct-registry
         technique tools\install-driver.ps1 uses for ScoBridge) and restarts it.
      3. VERIFIES the real registry Service value is WinUSB before claiming
         success, and returns a non-zero exit code if it did not take - so the
         caller (UsbHardwareSetup) never reports a false "ready".

    ASCII-only and -NonInteractive safe: no pause, no self-elevation (the caller
    is already elevated).
#>

#Requires -RunAsAdministrator
$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# The companion adapters this product supports:
# 1. TP-Link UB500: VID_2357&PID_0604
# 2. TP-Link UB400: VID_0A12&PID_0001
# 3. Realtek BT 5.4: VID_0BDA&PID_A728 / VID_0BDA&PID_876F
$SupportedHwPatterns = @('VID_2357&PID_0604', 'VID_0A12&PID_0001', 'VID_0BDA&PID_A728', 'VID_0BDA&PID_876F')

function Write-Line($msg, $color = 'Gray') { Write-Host "      $msg" -ForegroundColor $color }

function Get-TpLinkDevice {
    Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
        Where-Object {
            $id = $_.InstanceId
            $isMatch = $false
            foreach ($pat in $SupportedHwPatterns) {
                if ($id -like "*$pat*") { $isMatch = $true; break }
            }
            $isMatch
        } |
        Select-Object -First 1
}

function Get-DeviceService($instanceId) {
    try {
        (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Enum\$instanceId" -Name Service -ErrorAction Stop).Service
    } catch { $null }
}

function Test-OnWinUsb($instanceId) {
    $svc = Get-DeviceService $instanceId
    $props = try { Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Enum\$instanceId" -ErrorAction Stop } catch { $null }
    $hasFilter = ($props -and ($props.LowerFilters -or $props.UpperFilters))
    return ($svc -and $svc -ieq 'WinUSB' -and (-not $hasFilter))
}

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "  Dialer Automated Silent WinUSB Driver Activation" -ForegroundColor White
Write-Host "==========================================================" -ForegroundColor Cyan

# ---------------------------------------------------------------------------
# 1. Import Certificate into Windows Trusted Root & Trusted Publisher stores
# ---------------------------------------------------------------------------
$cerFile = Join-Path $ScriptDir "dialer_driver.cer"
if (Test-Path $cerFile) {
    Write-Host "[1/4] Adding Trusted Driver Certificate to Windows Store..." -ForegroundColor Cyan
    & certutil -addstore -f "Root" $cerFile | Out-Null
    & certutil -addstore -f "TrustedPublisher" $cerFile | Out-Null
    Write-Line "Certificate trusted successfully." Green
} else {
    Write-Host "[ERROR] Certificate file not found: $cerFile" -ForegroundColor Red
    exit 1
}

# ---------------------------------------------------------------------------
# 2. Add and Install the Signed Driver Package via Windows SetupAPI
# ---------------------------------------------------------------------------
$infFile = Join-Path $ScriptDir "tplink_winusb.inf"
if (-not (Test-Path $infFile)) {
    Write-Host "[ERROR] INF file not found: $infFile" -ForegroundColor Red
    exit 1
}
Write-Host "[2/4] Installing Signed WinUSB Driver Package into Windows Driver Store..." -ForegroundColor Cyan
$pnpOutput = & pnputil /add-driver $infFile /install 2>&1
$pnpOutput | ForEach-Object { Write-Line $_ }

# Detect a driver-store install failure (most commonly a stale/invalid catalog:
# "The hash for the file is not present in the specified catalog file"). This is
# NOT fatal and MUST NOT lead to any device disable/enable: the direct-registry
# WinUSB bind in step 3b needs no catalog at all, so we simply note it and let
# the flow fall through to that driverless path.
$catalogOk = ($LASTEXITCODE -eq 0) `
    -and (-not ($pnpOutput -match 'hash for the file is not present')) `
    -and (-not ($pnpOutput -match 'Failed to add driver'))
if (-not $catalogOk) {
    Write-Line "Driver-store install did not succeed (likely an invalid/stale catalog)." Yellow
    Write-Line "Falling back to the driverless WinUSB registry bind - no device disable/enable." Yellow
}

# The published OEM inf name (oemNN.inf) - needed to bind it to the device below.
$oemInf = $null
$m = ($pnpOutput | Select-String -Pattern 'Published Name\s*:\s*(oem\d+\.inf)' | Select-Object -First 1)
if ($m) { $oemInf = $m.Matches[0].Groups[1].Value }

# ---------------------------------------------------------------------------
# 3. FORCE the binding onto WinUSB
# ---------------------------------------------------------------------------
Write-Host "[3/4] Binding the TP-Link adapter to WinUSB..." -ForegroundColor Cyan

$dev = Get-TpLinkDevice
if (-not $dev) {
    Write-Line "TP-Link adapter not plugged in. Driver is pre-staged; it will bind when the adapter is connected." Yellow
    Write-Host "==========================================================" -ForegroundColor Yellow
    Write-Host "  DRIVER PRE-STAGED (adapter not present)" -ForegroundColor Yellow
    Write-Host "==========================================================" -ForegroundColor Yellow
    exit 0
}

$instanceId = $dev.InstanceId
Write-Line "Device: $instanceId (currently on '$(Get-DeviceService $instanceId)')"

# 3a. Ask PnP to (re)evaluate drivers for THIS device against the store. On
#     many systems this is enough to move it to our now-available WinUSB inf.
#     Skip the SetupAPI force-install if the catalog install already failed - it
#     would only fail again on the same hash error. The registry bind in 3b is
#     the reliable, catalog-free path in that case.
if ($catalogOk -and $oemInf) {
    try {
        & pnputil /add-driver $infFile /install /force 2>&1 | ForEach-Object { Write-Line $_ }
    } catch { Write-Line "pnputil force install: $($_.Exception.Message)" DarkYellow }
}
& pnputil /restart-device "$instanceId" 2>&1 | Out-Null
Start-Sleep -Seconds 2

# 3b. If it is STILL not on WinUSB, force the service binding directly on the
#     device's registry node. This is the decisive step: SetupAPI's ranking
#     keeps the in-box BTHUSB driver otherwise. Writing Service=WinUSB plus the
#     WinUSB device-interface config is exactly what winusb.inf would have set;
#     a device restart then loads WinUSB.sys as the function driver.
if (-not (Test-OnWinUsb $instanceId)) {
    Write-Line "SetupAPI kept the in-box driver; forcing WinUSB via the device registry node." Yellow
    $enumKey = "HKLM:\SYSTEM\CurrentControlSet\Enum\$instanceId"
    try {
        $prev = Get-DeviceService $instanceId
        if ($prev -and $prev -ine 'WinUSB') {
            New-ItemProperty -Path $enumKey -Name 'DialerPrevService' -Value $prev -PropertyType String -Force | Out-Null
        }
        Set-ItemProperty -Path $enumKey -Name 'Service' -Value 'WinUSB' -Type String

        # Device parameters WinUSB expects: expose the interface GUID so the app
        # (BTstack) can open the device. Matches winusb.inf's Dev_AddReg.
        $devParams = Join-Path $enumKey 'Device Parameters'
        if (-not (Test-Path $devParams)) { New-Item -Path $devParams -Force | Out-Null }
        New-ItemProperty -Path $devParams -Name 'DeviceInterfaceGUIDs' `
            -Value @('{A5DCBF10-6530-11D2-901F-00C04FB951ED}') -PropertyType MultiString -Force | Out-Null

        # Strip vendor filter drivers (e.g. RtkBtFilter) which intercept
        # HCI transfers and break WinUSB controller access.
        $props = Get-ItemProperty -Path $enumKey -ErrorAction SilentlyContinue
        if ($props.LowerFilters) {
            New-ItemProperty -Path $enumKey -Name 'DialerPrevLowerFilters' -Value $props.LowerFilters -PropertyType MultiString -Force | Out-Null
            Remove-ItemProperty -Path $enumKey -Name 'LowerFilters' -ErrorAction SilentlyContinue | Out-Null
        }
        if ($props.UpperFilters) {
            New-ItemProperty -Path $enumKey -Name 'DialerPrevUpperFilters' -Value $props.UpperFilters -PropertyType MultiString -Force | Out-Null
            Remove-ItemProperty -Path $enumKey -Name 'UpperFilters' -ErrorAction SilentlyContinue | Out-Null
        }

        & pnputil /restart-device "$instanceId" 2>&1 | Out-Null
        Start-Sleep -Seconds 2

        # A restart can fail to reload cleanly on the first try. We deliberately
        # do NOT disable the device here: disabling is a system-affecting action
        # this tool must never take. A second /restart-device is safe and usually
        # enough; if it still does not take, the user is told to re-plug the
        # adapter (see the failure message in step 4).
        if (-not (Test-OnWinUsb $instanceId)) {
            & pnputil /restart-device "$instanceId" 2>&1 | Out-Null
            Start-Sleep -Seconds 2
        }
    } catch {
        Write-Line "Direct WinUSB bind failed: $($_.Exception.Message)" Red
    }
}

# ---------------------------------------------------------------------------
# 4. Verify the REAL binding (never trust the steps above)
# ---------------------------------------------------------------------------
Write-Host "[4/4] Verifying the adapter is on WinUSB..." -ForegroundColor Cyan
$devAfter = Get-TpLinkDevice
$svcAfter = if ($devAfter) { Get-DeviceService $devAfter.InstanceId } else { $null }

if ($svcAfter -and $svcAfter -ieq 'WinUSB') {
    Write-Host "`n==========================================================" -ForegroundColor Green
    Write-Host "  DEVICE READY FOR NATIVE BTSTACK AUDIO DIALER!" -ForegroundColor White
    Write-Host "  Friendly Name: $($devAfter.FriendlyName)" -ForegroundColor Green
    Write-Host "  Service:       $svcAfter" -ForegroundColor Green
    Write-Host "  Status:        $($devAfter.Status)" -ForegroundColor Green
    Write-Host "==========================================================" -ForegroundColor Green
    exit 0
} else {
    Write-Host "`n==========================================================" -ForegroundColor Red
    Write-Host "  WINUSB BINDING DID NOT TAKE" -ForegroundColor White
    Write-Host "  Friendly Name: $(if ($devAfter) { $devAfter.FriendlyName } else { '(adapter not present)' })" -ForegroundColor Red
    Write-Host "  Service:       $(if ($svcAfter) { $svcAfter } else { 'unknown' })  (expected WinUSB)" -ForegroundColor Red
    Write-Host "  Try re-plugging the adapter; a reboot may be required if a" -ForegroundColor Red
    Write-Host "  previous driver is still held by the in-box Bluetooth stack." -ForegroundColor Red
    Write-Host "==========================================================" -ForegroundColor Red
    exit 2
}
