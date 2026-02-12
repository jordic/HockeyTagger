PROJECT := HockeyTagger.xcodeproj
SCHEME := HockeyTagger
CONFIGURATION := Release
DESTINATION := generic/platform=macOS

DERIVED_INTEL := ./.deriveddata_intel
DERIVED_UNIVERSAL := ./.deriveddata_universal

INTEL_APP := $(DERIVED_INTEL)/Build/Products/$(CONFIGURATION)/HockeyTagger.app
UNIVERSAL_APP := $(DERIVED_UNIVERSAL)/Build/Products/$(CONFIGURATION)/HockeyTagger.app

INTEL_BIN := $(INTEL_APP)/Contents/MacOS/HockeyTagger
UNIVERSAL_BIN := $(UNIVERSAL_APP)/Contents/MacOS/HockeyTagger

.PHONY: help build-intel build-universal where-intel where-universal where clean

help:
	@echo "Targets:"
	@echo "  make build-intel      Build Intel-only (x86_64)"
	@echo "  make build-universal  Build universal (arm64 + x86_64)"
	@echo "  make where            Print output paths for both builds"
	@echo "  make clean            Remove derived data used by this Makefile"

build-intel:
	xcodebuild -project "$(PROJECT)" -scheme "$(SCHEME)" -configuration "$(CONFIGURATION)" \
	-destination "$(DESTINATION)" -derivedDataPath "$(DERIVED_INTEL)" \
	CODE_SIGNING_ALLOWED=NO ARCHS=x86_64 ONLY_ACTIVE_ARCH=NO build
	@echo "Intel app: $(INTEL_APP)"
	@echo "Intel binary: $(INTEL_BIN)"

build-universal:
	xcodebuild -project "$(PROJECT)" -scheme "$(SCHEME)" -configuration "$(CONFIGURATION)" \
	-destination "$(DESTINATION)" -derivedDataPath "$(DERIVED_UNIVERSAL)" \
	CODE_SIGNING_ALLOWED=NO ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO build
	@echo "Universal app: $(UNIVERSAL_APP)"
	@echo "Universal binary: $(UNIVERSAL_BIN)"
	@lipo -info "$(UNIVERSAL_BIN)"

where-intel:
	@echo "Intel app: $(INTEL_APP)"
	@echo "Intel binary: $(INTEL_BIN)"

where-universal:
	@echo "Universal app: $(UNIVERSAL_APP)"
	@echo "Universal binary: $(UNIVERSAL_BIN)"

where: where-intel where-universal

clean:
	rm -rf "$(DERIVED_INTEL)" "$(DERIVED_UNIVERSAL)"
