# Flow — local voice dictation for macOS.
#
# The app needs the macOS 26 SDK (Foundation Models). Xcode 16.x lacks it, so the build prefers the
# Command Line Tools toolchain when it carries a macOS 26 SDK. XCTest is borrowed from Xcode when the
# chosen toolchain doesn't ship one. Override with DEVELOPER_DIR=... if you want a specific toolchain.

CLT := /Library/Developer/CommandLineTools
XCODE := $(shell xcode-select -p 2>/dev/null)
ifneq ($(wildcard $(CLT)/SDKs/MacOSX26*.sdk),)
  DEVELOPER_DIR ?= $(CLT)
else
  DEVELOPER_DIR ?= $(XCODE)
endif
export DEVELOPER_DIR

XC_PLATFORM := $(firstword $(wildcard /Applications/Xcode*.app/Contents/Developer/Platforms/MacOSX.platform/Developer))
ifeq ($(wildcard $(DEVELOPER_DIR)/Platforms/MacOSX.platform/Developer/Library/Frameworks/XCTest.framework),)
  TEST_FLAGS := -Xswiftc -F$(XC_PLATFORM)/Library/Frameworks -Xlinker -F$(XC_PLATFORM)/Library/Frameworks \
    -Xlinker -rpath -Xlinker $(XC_PLATFORM)/Library/Frameworks -Xswiftc -I$(XC_PLATFORM)/usr/lib \
    -Xlinker -L$(XC_PLATFORM)/usr/lib -Xlinker -rpath -Xlinker $(XC_PLATFORM)/usr/lib \
    -Xlinker -rpath -Xlinker $(XC_PLATFORM)/Library/PrivateFrameworks \
    -Xlinker -rpath -Xlinker $(dir $(patsubst %/,%,$(dir $(XC_PLATFORM))))../../../SharedFrameworks
endif

.PHONY: build bundle run test check-windows clean cert

build:
	swift build -c release

bundle: build
	scripts/bundle.sh

run: bundle
	open build/Flow.app

# When the toolchain has no xctest runner (Command Line Tools), run the bundle with Xcode's.
XCTEST_BIN := $(DEVELOPER_DIR)/usr/bin/xctest
ifeq ($(wildcard $(XCTEST_BIN)),)
  XCTEST_BIN := $(abspath $(XC_PLATFORM)/../../../usr/bin/xctest)
  XCTEST_ENV := DYLD_FRAMEWORK_PATH=$(XC_PLATFORM)/Library/Frameworks
endif

test:
	swift build --build-tests $(TEST_FLAGS)
	$(XCTEST_ENV) $(XCTEST_BIN) .build/debug/FlowPackageTests.xctest

check-windows: bundle
	build/Flow.app/Contents/MacOS/Flow --check-windows

cert:
	scripts/make_signing_cert.sh

clean:
	rm -rf .build build/Flow.app
