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
# Windows runs the recipes in PowerShell (tools/make.ps1) and zips with its
# built-in tar.exe (Windows 10+); get make with `winget install ezwinports.make`.
# Linux runs them in sh and needs bsdtar (libarchive).

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

# GNU make on Windows runs a .ONESHELL recipe as a .bat file through cmd.exe,
# whatever SHELL is set to, so PowerShell recipes can't be written inline:
# each recipe is one cmd line calling tools/make.ps1 (the logic is there).
# The AddOns folder is passed as "dir=<path>" so it is never an empty argument.
PS := powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/make.ps1

help:
	@$(PS) help "dir=$(ADDONS_DIR)" "$(VERSION)" "$(ZIP)"

setup:
	@$(PS) setup "dir=$(ADDONS_DIR)" "$(origin ADDONS_DIR)"

package:
	@$(PS) package "$(ZIP)" $(PACKS)

# The submake re-reads the toc, so the zip gets the new version.
patch minor major:
	@$(PS) bump $@ "$(VERSION)" $(TOCS) && "$(MAKE)" --no-print-directory all

publish-local:
	@$(PS) publish-local "dir=$(ADDONS_DIR)" $(PACKS)

else

SHELL := /bin/sh
.SHELLFLAGS := -ec

help:
	@echo 'make setup           set your WoW AddOns folder (now: $(or $(ADDONS_DIR),not set))'
	echo 'make package         build $(ZIP) from this working tree'
	echo 'make publish-local   deploy this working tree to your AddOns folder'
	echo 'make                 both of the above'
	echo 'make patch|minor|major   new version ($(VERSION) now), then both of the above'

endif

ifneq ($(OS),Windows_NT)

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
