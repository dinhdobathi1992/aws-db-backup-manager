WAILS   := $(shell go env GOPATH)/bin/wails
APPNAME := AWS DB Backup Manager
APP     := build/bin/$(APPNAME).app
VERSION := $(shell jq -r '.info.productVersion' wails.json 2>/dev/null)
ifeq ($(strip $(VERSION)),)
$(error could not read info.productVersion from wails.json; is jq installed?)
endif
DIST    := dist
ARTIFACT := $(DIST)/AWS-DB-Backup-Manager-$(VERSION)-macos-universal

.PHONY: dev build build-native sign verify dmg zip package icon policy-check test lint clean-dist

dev:
	ADBM_FIXTURES=1 $(WAILS) dev

# Universal (arm64 + amd64) release build. -clean wipes build/bin first so a
# stale single-arch binary can never end up in the bundle.
build:
	$(WAILS) build -platform darwin/universal -clean
	@lipo -info "$(APP)/Contents/MacOS/$(APPNAME)"

# Fast host-arch build for local iteration.
build-native:
	$(WAILS) build

# Ad-hoc signature: enough for Gatekeeper on the building Mac and for
# right-click > Open elsewhere. Notarization needs a Developer ID (see README).
sign:
	codesign --force --deep --sign - "$(APP)"
	codesign --verify --deep --strict --verbose=2 "$(APP)"

verify:
	@lipo -info "$(APP)/Contents/MacOS/$(APPNAME)"
	@/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' -c 'Print :CFBundleShortVersionString' -c 'Print :LSMinimumSystemVersion' -c 'Print :CFBundleIconFile' "$(APP)/Contents/Info.plist"
	@test -s "$(APP)/Contents/Resources/iconfile.icns" && echo "icon: $(APP)/Contents/Resources/iconfile.icns"
	@codesign --verify --deep --strict "$(APP)" && echo "codesign: valid (ad-hoc)"

dmg: | $(DIST)
	rm -rf "$(DIST)/dmg-staging" "$(ARTIFACT).dmg"
	mkdir -p "$(DIST)/dmg-staging"
	ditto "$(APP)" "$(DIST)/dmg-staging/$(APPNAME).app"
	ln -s /Applications "$(DIST)/dmg-staging/Applications"
	hdiutil create -volname "$(APPNAME)" -srcfolder "$(DIST)/dmg-staging" -fs HFS+ -format UDZO -ov "$(ARTIFACT).dmg"
	rm -rf "$(DIST)/dmg-staging"
	hdiutil verify "$(ARTIFACT).dmg"

zip: | $(DIST)
	rm -f "$(ARTIFACT).zip"
	ditto -c -k --sequesterRsrc --keepParent "$(APP)" "$(ARTIFACT).zip"

# Steps run in order even under make -j: each needs the previous one's output.
package:
	$(MAKE) policy-check
	$(MAKE) build
	$(MAKE) sign
	$(MAKE) verify
	$(MAKE) dmg
	$(MAKE) zip
	cd $(DIST) && shasum -a 256 "$(notdir $(ARTIFACT)).dmg" "$(notdir $(ARTIFACT)).zip" > SHA256SUMS
	@cat $(DIST)/SHA256SUMS

# Re-render the 1024px icon from its SVG source (needs librsvg).
icon:
	rsvg-convert -w 1024 -h 1024 build/appicon.svg -o build/appicon.png

policy-check:
	./scripts/policy-check.sh

$(DIST):
	mkdir -p $(DIST)

clean-dist:
	rm -rf $(DIST)

test:
	go test ./...
	cd frontend && pnpm exec tsc -b

lint:
	go vet ./...
	@out="$$(gofmt -l $$(go list -f '{{.Dir}}' ./...))"; if [ -n "$$out" ]; then echo "gofmt needed:"; echo "$$out"; exit 1; fi

# Native SwiftUI app (v0.2). Artifacts go to dist/<version>/.
.PHONY: build-native-app test-native policy-check-native package-native
build-native-app:
	./macos/scripts/make-app.sh
test-native:
	cd macos && swift test
policy-check-native:
	./macos/scripts/policy-check-native.sh
package-native:
	./macos/scripts/package-native.sh
