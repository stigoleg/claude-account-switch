APP_NAME    := Claude Profile Switcher
APP_BUNDLE  := ./build/$(APP_NAME).app
INSTALL_DIR := /Applications
SUPPORT_DIR := $(HOME)/Library/Application Support/ClaudeProfileSwitcher
DIST_DIR    := ./dist
# Recursively expanded so version.sh runs when a dist target actually fires.
VERSION      = $(shell ./Scripts/version.sh version)
ZIP_NAME     = ClaudeProfileSwitcher-$(VERSION).zip
DMG_NAME     = ClaudeProfileSwitcher-$(VERSION).dmg

.DEFAULT_GOAL := help

.PHONY: help build debug run test clean install uninstall xcode icon \
        version release-zip dmg checksums dist lint

help: ## Show this help
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "  \033[1m%-12s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

icon: ## Regenerate AppBundle/AppIcon.png and AppIcon.icns from the source script
	swift Scripts/generate-icon.swift
	./Scripts/make-icns.sh

build: ## Build release .app bundle (./build/Claude Profile Switcher.app)
	./build-app.sh release

debug: ## Build debug .app bundle
	./build-app.sh debug

run: build ## Build then launch the .app from ./build
	open "$(APP_BUNDLE)"

test: ## Run unit tests
	swift test

lint: ## Lint sources with the toolchain's swift format
	swift format lint --strict --recursive Sources Tests Package.swift

version: ## Print the resolved app version (git tag → version)
	@./Scripts/version.sh version

release-zip: build ## Zip the .app for distribution (ditto preserves the bundle)
	@mkdir -p $(DIST_DIR)
	ditto -c -k --sequesterRsrc --keepParent "$(APP_BUNDLE)" "$(DIST_DIR)/$(ZIP_NAME)"
	@echo "==> $(DIST_DIR)/$(ZIP_NAME)"

dmg: build ## Build a drag-to-Applications .dmg
	./Scripts/make-dmg.sh "$(APP_BUNDLE)" "$(DIST_DIR)/$(DMG_NAME)"

checksums: ## Write SHA256SUMS for everything in dist/
	cd $(DIST_DIR) && shasum -a 256 *.zip *.dmg > SHA256SUMS
	@cat $(DIST_DIR)/SHA256SUMS

dist: release-zip dmg checksums ## Build all release artifacts into ./dist

clean: ## Remove build artifacts (.build, ./build, ./dist)
	rm -rf .build build dist

install: build ## Install the bundle into /Applications (overwrites existing)
	@if [ -d "$(INSTALL_DIR)/$(APP_NAME).app" ]; then \
		echo "==> removing existing $(INSTALL_DIR)/$(APP_NAME).app"; \
		rm -rf "$(INSTALL_DIR)/$(APP_NAME).app"; \
	fi
	cp -R "$(APP_BUNDLE)" "$(INSTALL_DIR)/"
	@echo "==> installed to $(INSTALL_DIR)/$(APP_NAME).app"
	@echo "    First launch: right-click → Open to bypass Gatekeeper"
	@echo "    or run: xattr -d com.apple.quarantine \"$(INSTALL_DIR)/$(APP_NAME).app\""

uninstall: ## Remove installed bundle; prompt before nuking support dir
	@if [ -d "$(INSTALL_DIR)/$(APP_NAME).app" ]; then \
		rm -rf "$(INSTALL_DIR)/$(APP_NAME).app"; \
		echo "==> removed $(INSTALL_DIR)/$(APP_NAME).app"; \
	else \
		echo "==> nothing to remove at $(INSTALL_DIR)/$(APP_NAME).app"; \
	fi
	@if [ -d "$(SUPPORT_DIR)" ]; then \
		printf "Also remove $(SUPPORT_DIR)? [y/N] "; \
		read ans; \
		if [ "$$ans" = "y" ] || [ "$$ans" = "Y" ]; then \
			rm -rf "$(SUPPORT_DIR)"; \
			echo "==> removed $(SUPPORT_DIR)"; \
		fi \
	fi

xcode: ## Open the Swift package in Xcode
	open Package.swift
