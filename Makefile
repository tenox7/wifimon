-include .env

APP_NAME := WifiMon
BUILD_DIR := build
APP_DIR := $(BUILD_DIR)/$(APP_NAME).app
DMG_PATH := $(BUILD_DIR)/$(APP_NAME).dmg
MACOS_DIR := $(APP_DIR)/Contents/MacOS
RES_DIR := $(APP_DIR)/Contents/Resources
BINARY := $(MACOS_DIR)/$(APP_NAME)
ICON := $(BUILD_DIR)/AppIcon.icns
SIGNATURE := $(APP_DIR)/Contents/_CodeSignature/CodeResources
STAGING := $(BUILD_DIR)/dmg_staging

ARCH := $(shell uname -m)
SOURCES := $(wildcard Sources/*.swift)

.PHONY: app dmg release clean

app: $(SIGNATURE)
	@echo "Run with: open $(APP_DIR)"

dmg: $(DMG_PATH)

$(SIGNATURE): $(BINARY) $(RES_DIR)/AppIcon.icns $(APP_DIR)/Contents/Info.plist
	codesign --force --sign - $(APP_DIR)
	@echo "Built $(APP_DIR)"

$(BINARY): $(SOURCES) | $(MACOS_DIR)
	swiftc \
		-O \
		-parse-as-library \
		-target $(ARCH)-apple-macos13.0 \
		-o $@ \
		$(SOURCES)

$(ICON): scripts/gen_icon.swift | $(BUILD_DIR)
	swift scripts/gen_icon.swift $(BUILD_DIR)

$(RES_DIR)/AppIcon.icns: $(ICON) | $(RES_DIR)
	cp $< $@

$(APP_DIR)/Contents/Info.plist: Info.plist | $(APP_DIR)/Contents
	cp $< $@

$(BUILD_DIR) $(APP_DIR)/Contents $(MACOS_DIR) $(RES_DIR):
	mkdir -p $@

define build_dmg
	rm -rf $(STAGING) $(1)
	mkdir -p $(STAGING)
	cp -R $(APP_DIR) $(STAGING)/
	ln -s /Applications $(STAGING)/Applications
	hdiutil create -volname $(APP_NAME) -srcfolder $(STAGING) -ov -format UDZO $(1) > /dev/null
	rm -rf $(STAGING)
endef

$(DMG_PATH): $(SIGNATURE)
	$(call build_dmg,$@)
	@echo "Built $@"

release: $(BINARY) $(RES_DIR)/AppIcon.icns $(APP_DIR)/Contents/Info.plist
	@test -n "$(DEV_ID)" || { echo "DEV_ID not set — copy .env.example to .env and fill in"; exit 1; }
	@test -n "$(NOTARY_PROFILE)" || { echo "NOTARY_PROFILE not set — copy .env.example to .env and fill in"; exit 1; }
	codesign --force --options runtime --timestamp --sign "$(DEV_ID)" $(APP_DIR)
	$(call build_dmg,$(DMG_PATH))
	codesign --force --timestamp --sign "$(DEV_ID)" $(DMG_PATH)
	xcrun notarytool submit $(DMG_PATH) --keychain-profile "$(NOTARY_PROFILE)" --wait
	xcrun stapler staple $(DMG_PATH)
	@echo "Signed + notarized: $(DMG_PATH)"

clean:
	rm -rf $(BUILD_DIR)
	@echo "Cleaned $(BUILD_DIR)"
