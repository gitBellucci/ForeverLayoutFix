# ForeverLayoutFix disk bridge. Run with WoW CLOSED.
# Creates Interface\AddOns\!FLF_Data\Disk -> WTF\Account\<id>\SavedVariables
param([switch]$Elevated)

$ErrorActionPreference = "Stop"

function Test-IsAdmin {
	$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
	$principal = New-Object Security.Principal.WindowsPrincipal($identity)
	return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-WowRoot {
	$p = $PSScriptRoot
	# Setup -> addon -> AddOns -> Interface -> game root
	for ($i = 0; $i -lt 4; $i++) {
		$p = Split-Path $p -Parent
	}
	if (-not (Test-Path -LiteralPath (Join-Path $p "Interface\AddOns"))) {
		throw "Could not find the WoW folder from Setup. Keep FLF_Setup.cmd inside !ForeverLayoutFix\Setup."
	}
	return $p
}

$wowNames = @("Wow", "WowClassic", "WowClassicT", "Wow-64", "WorldOfWarcraft")
if (Get-Process -Name $wowNames -ErrorAction SilentlyContinue) {
	Write-Host "WoW is still running. Fully close the game, then run this again."
	exit 1
}

$wowRoot = Get-WowRoot
$addonsRoot = Join-Path $wowRoot "Interface\AddOns"
$accountRoot = Join-Path $wowRoot "WTF\Account"
$templateRoot = Join-Path $PSScriptRoot "Companion"

Write-Host "WoW folder: $wowRoot"

if (-not (Test-Path -LiteralPath $accountRoot)) {
	Write-Host "Could not find WTF\Account. Log into the game once, then run setup again."
	exit 1
}

$accounts = Get-ChildItem -Path $accountRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object {
	$sv = Join-Path $_.FullName "SavedVariables"
	if (Test-Path -LiteralPath $sv) {
		$dump = Join-Path $sv "!FLF_Data.lua"
		if (-not (Test-Path -LiteralPath $dump)) {
			$dump = Join-Path $sv "!ForeverLayoutFix.lua"
		}
		$item = $null
		if (Test-Path -LiteralPath $dump) { $item = Get-Item -LiteralPath $dump }
		[pscustomobject]@{
			Name = $_.Name
			Folder = $_
			SvDir = $sv
			Dump = $item
			Sort = if ($item) { $item.LastWriteTime } else { $_.LastWriteTime }
		}
	}
} | Sort-Object Sort -Descending

if (-not $accounts) {
	Write-Host "No account folders found. Log in once, close WoW, then run setup again."
	exit 1
}

$selected = $null
if (@($accounts).Count -eq 1) {
	$selected = @($accounts)[0]
} else {
	Write-Host ""
	Write-Host "Accounts:"
	$i = 1
	foreach ($a in @($accounts)) {
		$extra = if ($a.Dump) { "  (!ForeverLayoutFix.lua $($a.Dump.LastWriteTime.ToString('yyyy-MM-dd HH:mm')))" } else { "  (no dump yet)" }
		Write-Host ("  {0}. {1}{2}" -f $i, $a.Name, $extra)
		$i++
	}
	$raw = Read-Host "Pick account number"
	$num = 0
	[void][int]::TryParse($raw, [ref]$num)
	if ($num -lt 1 -or $num -gt @($accounts).Count) {
		Write-Host "Invalid choice."
		exit 1
	}
	$selected = @($accounts)[$num - 1]
}

Write-Host "Using account $($selected.Name)"
$svDir = $selected.SvDir
New-Item -ItemType Directory -Path $svDir -Force | Out-Null

$dumpPath = Join-Path $svDir "!ForeverLayoutFix.lua"
if (-not (Test-Path -LiteralPath $dumpPath)) {
	$seed = "ForeverLayoutFixAccountDB = {}`r`n"
	[IO.File]::WriteAllText($dumpPath, $seed)
	Write-Host "Created empty !ForeverLayoutFix.lua (log in and /flf save once after setup)."
}

$profilesPath = Join-Path $svDir "!FLF_Data.lua"
if (-not (Test-Path -LiteralPath $profilesPath)) {
	$seed = "ForeverLayoutFixProfilesDB = {`r`n[`"profiles`"] = {`r`n},`r`n[`"profileEnabled`"] = false,`r`n}`r`n"
	[IO.File]::WriteAllText($profilesPath, $seed)
	Write-Host "Created empty !FLF_Data.lua for layout profiles."
}

$dataRoot = Join-Path $addonsRoot "!FLF_Data"
$link = Join-Path $dataRoot "Disk"

function Install-Companion {
	if (-not (Test-Path -LiteralPath $templateRoot)) {
		throw "Companion template missing: $templateRoot"
	}
	New-Item -ItemType Directory -Path $dataRoot -Force | Out-Null
	Copy-Item -LiteralPath (Join-Path $templateRoot "!FLF_Data.toc") -Destination (Join-Path $dataRoot "!FLF_Data.toc") -Force
	Copy-Item -LiteralPath (Join-Path $templateRoot "Begin.lua") -Destination (Join-Path $dataRoot "Begin.lua") -Force
	Copy-Item -LiteralPath (Join-Path $templateRoot "End.lua") -Destination (Join-Path $dataRoot "End.lua") -Force
	$stub = Join-Path $templateRoot "PublishedProfiles.lua"
	$published = Join-Path $dataRoot "PublishedProfiles.lua"
	if ((Test-Path -LiteralPath $stub) -and -not (Test-Path -LiteralPath $published)) {
		Copy-Item -LiteralPath $stub -Destination $published -Force
	}

	$existing = Get-Item -LiteralPath $link -Force -ErrorAction SilentlyContinue
	if ($existing) {
		if ($existing.LinkType -ne "Junction") {
			throw "Disk path exists and is not a junction. Move or delete Interface\AddOns\!FLF_Data\Disk and retry."
		}
		# Delete the junction only — never recurse into SavedVariables.
		[IO.Directory]::Delete($link)
	}
	New-Item -ItemType Junction -Path $link -Target $svDir -ErrorAction Stop | Out-Null
	$actual = Get-Item -LiteralPath $link -Force
	$target = [IO.Path]::GetFullPath([string]@($actual.Target)[0])
	$want = [IO.Path]::GetFullPath($svDir)
	if ($actual.LinkType -ne "Junction" -or $target -ine $want) {
		throw "Junction verification failed."
	}
}

function Publish-Profiles {
	$src = Join-Path $svDir "!FLF_Data.lua"
	if (-not (Test-Path -LiteralPath $src)) {
		throw "No profile dump yet. Log in, /flf profiles, Save settings, close WoW, then run this again."
	}
	$text = [IO.File]::ReadAllText($src)
	if ($text -notmatch 'ForeverLayoutFixProfilesDB') {
		throw "!FLF_Data.lua does not contain a profile dump. Save settings in-game first."
	}
	if ($text -notmatch '\[\"profiles\"\]') {
		throw "Profile dump is empty. On your main character, /flf profiles -> Save settings, then close WoW and run this again."
	}
	# Always assign to a snapshot global, then End.lua merges into native SV.
	# Never wrap in an empty-guard: leftover alt profiles would hide the main layout.
	$text = [regex]::Replace($text.Trim(), 'ForeverLayoutFixProfilesDB\s*=', 'FLF_PublishedSnapshot =', 1)
	if ($text -notmatch 'FLF_PublishedSnapshot\s*=') {
		throw "Could not convert the profile dump. Save settings in-game, close WoW, then run this again."
	}
	$dest = Join-Path $dataRoot "PublishedProfiles.lua"
	[IO.File]::WriteAllText($dest, $text + [Environment]::NewLine)
	Write-Host ("Published profiles: {0} ({1} bytes)" -f $dest, (Get-Item -LiteralPath $dest).Length)
}

try {
	Install-Companion
	Publish-Profiles
} catch {
	if (-not $Elevated -and -not (Test-IsAdmin)) {
		Write-Host "Administrator permission needed to write into AddOns. Prompting..."
		$arg = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Elevated"
		Start-Process -FilePath "powershell.exe" -Verb RunAs -ArgumentList $arg | Out-Null
		exit 0
	}
	throw
}

Write-Host ""
Write-Host "Profiles published into the addon folder."
Write-Host "  Companion: $dataRoot"
Write-Host ""
Write-Host "Keep BOTH addons enabled: !ForeverLayoutFix and !FLF_Data"
Write-Host "Log into any character. You should see the saved profile."
Write-Host ""
Write-Host "After you change the layout: Save settings in /flf profiles,"
Write-Host "close WoW, and run this .cmd again before switching characters."

if ($Elevated) {
	Write-Host ""
	Write-Host "Press Enter to close."
	[void][Console]::ReadLine()
}
