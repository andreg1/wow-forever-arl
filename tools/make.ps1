# Windows side of the Makefile. GNU make on Windows runs a .ONESHELL recipe
# as a .bat file through cmd.exe whatever SHELL says, so multi-line
# PowerShell recipes can't live in the Makefile itself; each Windows recipe
# is one line that calls this script with the target and make's values.
#
#   make.ps1 help dir=<addonsDir> <version> <zip>
#   make.ps1 setup dir=<addonsDir> <origin of ADDONS_DIR>
#   make.ps1 package <zip> <pack>...
#   make.ps1 bump patch|minor|major <version> <toc>...
#   make.ps1 publish-local dir=<addonsDir> <pack>...
#
# The AddOns folder comes as "dir=<path>" so it is never an empty argument
# (Windows PowerShell drops those, which would shift the others).
param(
  [Parameter(Mandatory)][string]$Target,
  [Parameter(ValueFromRemainingArguments)][string[]]$Rest
)
$ErrorActionPreference = 'Stop'
$here = (Get-Location).ProviderPath

function Clean([string]$dir) {
  return $dir.Trim().Trim([char]34, [char]39).TrimEnd([char]92, [char]47)
}

function DirArg([string]$arg) {
  if ($arg -notlike 'dir=*') { Write-Host ('Expected dir=<path>, got: ' + $arg); exit 1 }
  return $arg.Substring(4)
}

switch ($Target) {
  'help' {
    $dir, $version, $zip = $Rest
    $dir = DirArg $dir
    $shown = if ($dir) { $dir } else { 'not set' }
    Write-Host "make setup           set your WoW AddOns folder (now: $shown)"
    Write-Host "make package         build $zip from this working tree"
    Write-Host 'make publish-local   deploy this working tree to your AddOns folder'
    Write-Host 'make                 both of the above'
    Write-Host "make patch|minor|major   new version ($version now), then both of the above"
  }

  'setup' {
    $dir, $origin = $Rest
    $dir = DirArg $dir
    if ($origin -ne 'command line') {
      $shown = if ($dir) { ' [' + $dir + ']' } else { '' }
      $answer = Read-Host ('WoW AddOns folder (..._forever_\Interface\AddOns)' + $shown)
      if ($answer) { $dir = $answer }
    }
    $dir = Clean $dir
    if (-not $dir) { Write-Host 'No folder given.'; exit 1 }
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { Write-Host ('Not a folder: ' + $dir); exit 1 }
    $dir = (Resolve-Path -LiteralPath $dir).ProviderPath
    if ($dir -eq $here) { Write-Host 'That is this repo, not the AddOns folder.'; exit 1 }
    if ((Split-Path -Leaf $dir) -ne 'AddOns') { Write-Host ('Warning: ' + $dir + ' does not end in AddOns.') }
    [IO.File]::WriteAllText((Join-Path $here 'local.mk'), 'ADDONS_DIR := ' + $dir + [Environment]::NewLine)
    Write-Host ('Saved to local.mk: ' + $dir)
  }

  'package' {
    $zip, $packs = $Rest
    $zipPath = Join-Path $here $zip
    New-Item -ItemType Directory -Force (Split-Path -Parent $zipPath) | Out-Null
    if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath }
    # The zip holds the addon folders at its root; LICENSE goes inside
    # ARLExtensions/. Windows' tar.exe has no -s (rename), so the folders
    # are staged in a temp folder with LICENSE put in place, and zipped from there.
    $stage = Join-Path ([IO.Path]::GetTempPath()) ('arl-package-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force $stage | Out-Null
    try {
      foreach ($p in $packs) { Copy-Item -LiteralPath (Join-Path $here $p) -Destination (Join-Path $stage $p) -Recurse }
      Copy-Item -LiteralPath (Join-Path $here 'LICENSE') -Destination (Join-Path $stage 'ARLExtensions\LICENSE')
      & (Join-Path $env:SystemRoot 'System32\tar.exe') -a -cf $zipPath -C $stage @packs
      if ($LASTEXITCODE) { exit $LASTEXITCODE }
    } finally {
      Remove-Item -LiteralPath $stage -Recurse -Force
    }
    Write-Host ('Packaged ' + $zip)
  }

  'bump' {
    $level, $version, $tocs = $Rest
    if ($version -notmatch '^\d+\.\d+\.\d+$') { Write-Host ('Bad version in ARLExtensions.toc: ' + $version); exit 1 }
    $a, $b, $c = $version.Split('.') | ForEach-Object { [int]$_ }
    switch ($level) {
      'major' { $a++; $b = 0; $c = 0 }
      'minor' { $b++; $c = 0 }
      'patch' { $c++ }
      default { Write-Host ('Unknown level: ' + $level); exit 1 }
    }
    $new = '{0}.{1}.{2}' -f $a, $b, $c
    foreach ($t in $tocs) {
      $path = Join-Path $here $t
      $text = [IO.File]::ReadAllText($path)
      [IO.File]::WriteAllText($path, ($text -replace '(?m)^## Version: [0-9.]+', ('## Version: ' + $new)))
    }
    Write-Host ('Version ' + $version + ' -> ' + $new)
  }

  'publish-local' {
    $dir, $packs = $Rest
    $dir = DirArg $dir
    $dir = if ($dir) { Clean $dir } else { '' }
    if (-not $dir) { Write-Host 'No AddOns folder set: run make setup first.'; exit 1 }
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { Write-Host ('AddOns folder not found: ' + $dir + ' (run make setup)'); exit 1 }
    if ((Resolve-Path -LiteralPath $dir).ProviderPath -eq $here) { Write-Host 'ADDONS_DIR is this repo; run make setup.'; exit 1 }
    foreach ($p in $packs) {
      $target = Join-Path $dir $p
      if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force }
      Copy-Item -LiteralPath (Join-Path $here $p) -Destination $target -Recurse
    }
    Write-Host ('Deployed ' + $packs.Count + ' folders to ' + $dir + '. /reload in game (restart the client after a .toc change).')
  }

  default { Write-Host ('Unknown target: ' + $Target); exit 1 }
}
