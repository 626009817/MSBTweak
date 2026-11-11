SDK ?= iphoneos
ARCHS ?= arm64 arm64e
MIN_IOS ?= 14.0
BUILD_DIR := build/$(SDK)
TARGET := $(BUILD_DIR)/MSBTweak.dylib
SOURCES := $(wildcard Sources/*.m)
HEADERS := $(wildcard Sources/*.h)
SDKROOT := $(shell xcrun --sdk $(SDK) --show-sdk-path)
CC := $(shell xcrun --sdk $(SDK) --find clang)
ARCH_FLAGS := $(foreach arch,$(ARCHS),-arch $(arch))
ifeq ($(SDK),iphonesimulator)
MIN_FLAG := -mios-simulator-version-min=$(MIN_IOS)
else
MIN_FLAG := -miphoneos-version-min=$(MIN_IOS)
endif
FRAMEWORKS := Foundation UIKit AVFoundation CoreLocation MapKit PhotosUI CoreMedia CoreVideo ImageIO QuartzCore CoreImage

.PHONY: all clean verify
all: $(TARGET)

$(TARGET): $(SOURCES) $(HEADERS) Makefile
	@mkdir -p $(BUILD_DIR)
	$(CC) -isysroot $(SDKROOT) $(ARCH_FLAGS) $(MIN_FLAG) -fobjc-arc -fmodules \
		-Wall -Wextra -Werror -Wno-deprecated-declarations -O2 -dynamiclib \
		-install_name @rpath/MSBTweak.dylib -I Sources $(SOURCES) \
		$(foreach framework,$(FRAMEWORKS),-framework $(framework)) -o $@
	codesign --force --sign - $@

verify: $(TARGET)
	file $(TARGET)
	xcrun lipo -info $(TARGET)
	codesign --verify --verbose=2 $(TARGET)
	xcrun otool -L $(TARGET)

clean:
	rm -rf build
