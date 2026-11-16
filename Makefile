# ARL Extensions: build and deploy helpers for Linux and Windows.
#
#   make setup           ask for your WoW AddOns folder, saved in local.mk (not committed)
#   make setup ADDONS_DIR=<path>   the same without the question
#   make package         dist/ARLExtensions-<version>.zip, ready to send to friends
#   make publish-local   copy ARLExtensions and every ARLE_* pack into your AddOns folder
#   make                 package + publish-local (rebuild while working on a change)
#   make patch|minor|major   bump ## Version in every toc, then package + publish-local
#
# Versioning rules are in AGENTS.md ("Versioning").
#
# Windows runs the recipes in PowerShell and zips with its built-in tar.exe
# (Windows 10+); get make with `winget install ezwinports.make`. Linux runs
# them in sh and needs bsdtar (libarchive).

-include local.mk

PACKS := ARLExtensions $(sort $(wildcard ARLE_*))
TOCS := $(wildcard ARLExtensions/*.toc ARLE_*/*.toc)
# "## Version: 0.1.0" in the host toc, read by make itself (no shell needed).
VERSION := $(patsubst VERSION=%,%,$(filter VERSION=%,$(subst ## Version: ,VERSION=,$(file < ARLExtensions/ARLExtensions.toc))))
ZIP := dist/ARLExtensions-$(VERSION).zip
# The zip holds the addon folders at its root (extract into AddOns); the MIT
# LICENSE travels inside ARLExtensions/.
TAR_ARGS := -a -cf $(ZIP) -s ,^LICENSE$$,ARLExtensions/LICENSE, $(PACKS) LICENSE

.DEFAULT_GOAL := all
.ONESHELL:
.PHONY: all help setup package publish-local patch minor major

all: package publish-local

ifeq ($(OS),Windows_NT)
SHELL := powershell.exe
.SHELLFLAGS := -NoProfile -ExecutionPolicy Bypass -Command
else
SHELL := /bin/sh
.SHELLFLAGS := -ec
endif

help:
	@echo 'make setup           set your WoW AddOns folder (now: $(or $(ADDONS_DIR),not set))'
	echo 'make package         build $(ZIP) from this working tree'
	echo 'make publish-local   deploy this working tree to your AddOns folder'
	echo 'make                 both of the above'
	echo 'make patch|minor|major   new version ($(VERSION) now), then both of the above'

ifeq ($(OS),Windows_NT)

setup:
	@$$ErrorActionPreference = 'Stop'
	$$dir = '$(ADDONS_DIR)'
	if ('$(origin ADDONS_DIR)' -ne 'command line') {
	  $$shown = if ($$dir) { ' [' + $$dir + ']' } else { '' }
	  $$answer = Read-Host ('WoW AddOns folder (..._forever_\Interface\AddOns)' + $$shown)
	  if ($$answer) { $$dir = $$answer }
	}
	$$dir = $$dir.Trim().Trim([char]34, [char]39).TrimEnd([char]92, [char]47)
	if (-not $$dir) { Write-Host 'No folder given.'; exit 1 }
	if (-not (Test-Path -LiteralPath $$dir -PathType Container)) { Write-Host ('Not a folder: ' + $$dir); exit 1 }
	$$dir = (Resolve-Path -LiteralPath $$dir).ProviderPath
	$$here = (Get-Location).ProviderPath
	if ($$dir -eq $$here) { Write-Host 'That is this repo, not the AddOns folder.'; exit 1 }
	if ((Split-Path -Leaf $$dir) -ne 'AddOns') { Write-Host ('Warning: ' + $$dir + ' does not end in AddOns.') }
	[IO.File]::WriteAllText((Join-Path $$here 'local.mk'), 'ADDONS_DIR := ' + $$dir + [Environment]::NewLine)
	Write-Host ('Saved to local.mk: ' + $$dir)

package:
	@$$ErrorActionPreference = 'Stop'
	New-Item -ItemType Directory -Force dist | Out-Null
	if (Test-Path -LiteralPath '$(ZIP)') { Remove-Item -LiteralPath '$(ZIP)' }
	& (Join-Path $$env:SystemRoot 'System32\tar.exe') $(TAR_ARGS)
	if ($$LASTEXITCODE) { exit $$LASTEXITCODE }
	Write-Host 'Packaged $(ZIP)'

# The submake re-reads the toc, so the zip gets the new version.
patch minor major:
	@$$ErrorActionPreference = 'Stop'
	if ('$(VERSION)' -notmatch '^\d+\.\d+\.\d+$$') { Write-Host 'Bad version in ARLExtensions.toc: $(VERSION)'; exit 1 }
	$$a, $$b, $$c = '$(VERSION)'.Split('.') | ForEach-Object { [int]$$_ }
	switch ('$@') { 'major' { $$a++; $$b = 0; $$c = 0 } 'minor' { $$b++; $$c = 0 } 'patch' { $$c++ } }
	$$new = '{0}.{1}.{2}' -f $$a, $$b, $$c
	foreach ($$t in '$(TOCS)'.Split(' ')) {
	  $$path = Join-Path (Get-Location).ProviderPath $$t
	  $$text = [IO.File]::ReadAllText($$path)
	  [IO.File]::WriteAllText($$path, ($$text -replace '(?m)^## Version: [0-9.]+', ('## Version: ' + $$new)))
	}
	Write-Host ('Version $(VERSION) -> ' + $$new)
	& '$(MAKE)' --no-print-directory all
	if ($$LASTEXITCODE) { exit $$LASTEXITCODE }

publish-local:
	@$$ErrorActionPreference = 'Stop'
	$$dir = '$(ADDONS_DIR)'
	if (-not $$dir) { Write-Host 'No AddOns folder set: run make setup first.'; exit 1 }
	if (-not (Test-Path -LiteralPath $$dir -PathType Container)) { Write-Host ('AddOns folder not found: ' + $$dir + ' (run make setup)'); exit 1 }
	if ((Resolve-Path -LiteralPath $$dir).ProviderPath -eq (Get-Location).ProviderPath) { Write-Host 'ADDONS_DIR is this repo; run make setup.'; exit 1 }
	foreach ($$p in '$(PACKS)'.Split(' ')) {
	  $$target = Join-Path $$dir $$p
	  if (Test-Path -LiteralPath $$target) { Remove-Item -LiteralPath $$target -Recurse -Force }
	  Copy-Item -LiteralPath $$p -Destination $$target -Recurse
	}
	Write-Host ('Deployed $(words $(PACKS)) folders to ' + $$dir + '. /reload in game (restart the client after a .toc change).')

else

setup:
	@dir='$(ADDONS_DIR)'
	if [ '$(origin ADDONS_DIR)' != 'command line' ]; then
	  printf 'WoW AddOns folder (..._forever_/Interface/AddOns)%s: ' "$${dir:+ [$$dir]}"
	  read -r answer || true
	  if [ -n "$$answer" ]; then dir=$$answer; fi
	fi
	dir=$$(printf '%s' "$$dir" | sed -e "s/^[\"']//" -e "s/[\"']$$//")
	case $$dir in "~"/*) dir=$$HOME/$${dir#"~/"} ;; esac
	dir=$${dir%/}
	[ -n "$$dir" ] || { echo 'No folder given.' >&2; exit 1; }
	[ -d "$$dir" ] || { echo "Not a folder: $$dir" >&2; exit 1; }
	dir=$$(cd "$$dir" && pwd -P)
	[ "$$dir" != "$$(pwd -P)" ] || { echo 'That is this repo, not the AddOns folder.' >&2; exit 1; }
	case $$(basename "$$dir") in [Aa][Dd][Dd][Oo][Nn][Ss]) ;; *) echo "Warning: $$dir does not end in AddOns." >&2 ;; esac
	printf 'ADDONS_DIR := %s\n' "$$dir" > local.mk
	echo "Saved to local.mk: $$dir"

package:
	@command -v bsdtar >/dev/null || { echo 'package needs bsdtar (libarchive).' >&2; exit 1; }
	mkdir -p dist
	rm -f '$(ZIP)'
	bsdtar $(TAR_ARGS)
	echo 'Packaged $(ZIP)'

# The submake re-reads the toc, so the zip gets the new version.
patch minor major:
	@v='$(VERSION)'
	printf '%s\n' "$$v" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$$' || { echo "Bad version in ARLExtensions.toc: $$v" >&2; exit 1; }
	IFS=. ; set -- $$v ; unset IFS
	a=$$1 b=$$2 c=$$3
	case '$@' in major) a=$$((a + 1)) b=0 c=0 ;; minor) b=$$((b + 1)) c=0 ;; patch) c=$$((c + 1)) ;; esac
	new=$$a.$$b.$$c
	sed -i "s/^## Version: [0-9.]*/## Version: $$new/" $(TOCS)
	echo "Version $$v -> $$new"
	$(MAKE) --no-print-directory all

publish-local:
	@dir='$(ADDONS_DIR)'
	[ -n "$$dir" ] || { echo 'No AddOns folder set: run make setup first.' >&2; exit 1; }
	[ -d "$$dir" ] || { echo "AddOns folder not found: $$dir (run make setup)" >&2; exit 1; }
	[ "$$(cd "$$dir" && pwd -P)" != "$$(pwd -P)" ] || { echo 'ADDONS_DIR is this repo; run make setup.' >&2; exit 1; }
	for p in $(PACKS); do
	  rm -rf "$$dir/$$p"
	  cp -R "$$p" "$$dir/$$p"
	done
	echo "Deployed $(words $(PACKS)) folders to $$dir. /reload in game (restart the client after a .toc change)."

endif
