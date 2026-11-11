ROOT := $(abspath ..)
SDKROOT := $(shell xcrun --sdk iphonesimulator --show-sdk-path)
CC := $(shell xcrun --sdk iphonesimulator --find clang)
APP := $(ROOT)/build/tests/MSBTweakTestHost.app
LIB := $(ROOT)/build/iphonesimulator/MSBTweak.dylib

.PHONY: all library
all: library
	@mkdir -p $(APP)/Frameworks
	cp $(LIB) $(APP)/Frameworks/MSBTweak.dylib
	cp Host/Info.plist $(APP)/Info.plist
	$(CC) -isysroot $(SDKROOT) -arch arm64 -mios-simulator-version-min=14.0 -fobjc-arc \
		-fmodules -Wall -Wextra -Wno-deprecated-declarations -Wno-nonnull -O0 -g \
		-I $(ROOT)/Sources Host/main.m $(LIB) \
		-Wl,-rpath,@executable_path/Frameworks -framework UIKit -framework Foundation \
		-framework AVFoundation -framework CoreLocation -framework CoreVideo -o $(APP)/MSBTweakTestHost
	codesign --force --sign - $(APP)/Frameworks/MSBTweak.dylib
	codesign --force --sign - $(APP)

library:
	$(MAKE) -C $(ROOT) SDK=iphonesimulator ARCHS=arm64
