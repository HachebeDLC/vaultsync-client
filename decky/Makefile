# Makefile for VaultSync Decky Plugin

PLUGIN_NAME = vaultsync-decky
BUILD_DIR = dist
OUT_FILE = $(PLUGIN_NAME).decky
DECKY_CLI = ../utils/decky-cli

all: build

build:
	@echo "🏗️ Building frontend..."
	# pnpm is required for official decky-cli builds
	# pnpm install && pnpm run build
	@echo "📦 Packaging plugin..."
	# Use official CLI if available, fallback to manual tar
	if [ -f $(DECKY_CLI) ]; then \
		$(DECKY_CLI) plugin build .; \
	else \
		mkdir -p $(BUILD_DIR)/$(PLUGIN_NAME); \
		cp -r main.py settings.py plugin.json dist assets $(BUILD_DIR)/$(PLUGIN_NAME)/; \
		cd $(BUILD_DIR) && tar -cvzf ../$(OUT_FILE) $(PLUGIN_NAME); \
	fi
	@echo "✅ Done!"

clean:
	rm -rf $(BUILD_DIR) $(OUT_FILE) node_modules

.PHONY: all build clean
