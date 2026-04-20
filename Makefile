APP_NAME := WifiMon
BUILD_DIR := build
APP_DIR := $(BUILD_DIR)/$(APP_NAME).app
DMG_PATH := $(BUILD_DIR)/$(APP_NAME).dmg
MACOS_DIR := $(APP_DIR)/Contents/MacOS
RES_DIR := $(APP_DIR)/Contents/Resources
BINARY := $(MACOS_DIR)/$(APP_NAME)
ICON := $(BUILD_DIR)/AppIcon.icns
SIGNATURE := $(APP_DIR)/Contents/_CodeSignature/CodeResources

ARCH := $(shell uname -m)
SOURCES := $(wildcard Sources/*.swift)

.PHONY: app dmg clean

app: $(SIGNATURE)
	@echo "Run with: open $(APP_DIR)"

dmg: $(DMG_PATH)

$(SIGNATURE): $(BINARY) $(RES_DIR)/AppIcon.icns $(APP_DIR)/Contents/Info.plist
	codesign --force --deep --sign - $(APP_DIR)
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

$(DMG_PATH): $(SIGNATURE)
	rm -rf $(BUILD_DIR)/dmg_staging $@
	mkdir -p $(BUILD_DIR)/dmg_staging
	cp -R $(APP_DIR) $(BUILD_DIR)/dmg_staging/
	ln -s /Applications $(BUILD_DIR)/dmg_staging/Applications
	hdiutil create \
		-volname $(APP_NAME) \
		-srcfolder $(BUILD_DIR)/dmg_staging \
		-ov \
		-format UDZO \
		$@ > /dev/null
	rm -rf $(BUILD_DIR)/dmg_staging
	@echo "Built $@"

clean:
	rm -rf $(BUILD_DIR)
	@echo "Cleaned $(BUILD_DIR)"
