<#
.SYNOPSIS
  Installs Quartus Prime Lite (with Cyclone V support) to D:\ and the
  USB-Blaster II driver used by the DE1-SoC.

.DESCRIPTION
  Download these two files from Altera's download page for Quartus Prime Lite
  (Windows, "Individual Files" tab) into the same folder:

    QuartusLiteSetup-<version>-windows.exe
    cyclonev-<version>.qdz

  Then run, from PowerShell:

    powershell -ExecutionPolicy Bypass -File scripts\de1soc\install-quartus.ps1 -InstallerDir "$env:USERPROFILE\Downloads"

  The installer picks up the .qdz device file automatically when it sits next
  to the setup .exe. Questa (the simulator) is not needed for this project.

.PARAMETER InstallerDir
  Folder holding the setup .exe and cyclonev .qdz. Default: your Downloads folder.

.PARAMETER InstallRoot
  Where to install. Default: D:\intelFPGA_lite\<version>.
#>
param(
	[string]$InstallerDir = (Join-Path $env:USERPROFILE "Downloads"),
	[string]$InstallRoot = ""
)

$ErrorActionPreference = "Stop"

$setup = Get-ChildItem -Path $InstallerDir -Filter "QuartusLiteSetup-*-windows.exe" -ErrorAction SilentlyContinue |
	Sort-Object Name -Descending | Select-Object -First 1
if (-not $setup) {
	$qinst = Get-ChildItem -Path $InstallerDir -Filter "qinst-lite-windows-*.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
	if ($qinst) {
		Write-Host "Found the online installer $($qinst.Name) but not the full QuartusLiteSetup .exe."
		Write-Host "Launching it; choose Quartus Prime Lite + Cyclone V and set the install folder to D:\intelFPGA_lite."
		Start-Process -FilePath $qinst.FullName -Wait
		Write-Host "When it finishes, re-run this script with -InstallerDir pointing at an empty folder to install the driver only."
		exit 0
	}
	Write-Host "ERROR: No QuartusLiteSetup-*-windows.exe found in $InstallerDir" -ForegroundColor Red
	exit 1
}

# QuartusLiteSetup-25.1std.0.1129-windows.exe -> 25.1std
$version = ($setup.Name -replace '^QuartusLiteSetup-', '' -replace '-windows\.exe$', '') -replace '^(\d+\.\d+(std)?(\.\d+)?).*$', '$1'
$version = $version -replace '\.0$', ''
if (-not $InstallRoot) { $InstallRoot = "D:\intelFPGA_lite\$version" }

$qdz = Get-ChildItem -Path $InstallerDir -Filter "cyclonev-*.qdz" -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $qdz) {
	Write-Host "ERROR: cyclonev-*.qdz not found next to $($setup.Name). The DE1-SoC needs Cyclone V device support." -ForegroundColor Red
	exit 1
}

Write-Host "Installer : $($setup.FullName)"
Write-Host "Devices   : $($qdz.Name)"
Write-Host "Target    : $InstallRoot"

$quartusExe = Join-Path $InstallRoot "quartus\bin64\quartus_sh.exe"
if (Test-Path $quartusExe) {
	Write-Host "Quartus is already installed at $InstallRoot; skipping the main install."
} else {
	Write-Host "Installing Quartus Prime Lite (this takes 10-30 minutes)..."
	$p = Start-Process -FilePath $setup.FullName -Wait -PassThru -ArgumentList @(
		"--mode", "unattended",
		"--unattendedmodeui", "minimal",
		"--installdir", "`"$InstallRoot`"",
		"--accept_eula", "1"
	)
	if ($p.ExitCode -ne 0 -or -not (Test-Path $quartusExe)) {
		Write-Host "ERROR: Quartus install failed (exit code $($p.ExitCode))." -ForegroundColor Red
		exit 1
	}
}

# USB-Blaster II driver (the DE1-SoC's on-board programmer). Needs admin.
$driverDir = Join-Path $InstallRoot "quartus\drivers\usb-blaster-ii"
if (Test-Path $driverDir) {
	Write-Host "Installing the USB-Blaster II driver (Windows will ask for administrator permission)..."
	$p = Start-Process -FilePath "pnputil.exe" -Verb RunAs -Wait -PassThru -ArgumentList @(
		"/add-driver", "`"$driverDir\*.inf`"", "/subdirs", "/install"
	)
	if ($p.ExitCode -ne 0) {
		Write-Host "WARNING: pnputil returned $($p.ExitCode). If the board is not detected, install the driver from Device Manager, pointing it at $driverDir" -ForegroundColor Yellow
	}
} else {
	Write-Host "WARNING: $driverDir not found; install the USB-Blaster II driver manually." -ForegroundColor Yellow
}

# Let the build/program scripts find Quartus even if the installer did not set this.
[Environment]::SetEnvironmentVariable("QUARTUS_ROOTDIR", (Join-Path $InstallRoot "quartus"), "User")

Write-Host ""
Write-Host "Done. Quartus is in $InstallRoot" -ForegroundColor Green
Write-Host "Open a NEW terminal, plug in the DE1-SoC (USB-Blaster II port, next to the power jack) and run:"
Write-Host "  scripts\de1soc\build.bat     (compile, ~10-20 min)"
Write-Host "  scripts\de1soc\program.bat   (load into the FPGA)"
Write-Host "  scripts\test\selftest.bat    (verify on hardware)"
