#
# Makefile — fizzbuzz
#
# Builds the FizzBuzz CLI (0..1000 inclusive) as:
#   - a macOS "Quad-Fat" universal binary (ppc/i386/x86_64/arm64)
#   - an iOS FAT binary (armv7/arm64), ad-hoc signed
#
# The Apple slices require cross toolchains that only exist in CI
# (see .github/workflows/build.yml). The Makefile is toolchain-agnostic:
# every slice reads its compiler/SDK from an environment variable, so the
# same Makefile drives both local and CI builds. When a toolchain is not
# present, the corresponding slice target fails at *run* time with a clear
# message instead of a cryptic error, and `make -n` (dry run) still prints
# the full plan.
#
# Local (aarch64 or x86_64 Linux, no Apple toolchains):
#   make test-host        # always works
#   make -n all           # dry run, prints what CI would do
#   make slices           # fails clearly per missing toolchain
#
# In CI (all toolchains staged under toolchain/):
#   make all              # slices + mac-fat + ios-fat
#   make validate         # lipo -info + per-slice min-OS manifest
#
# Layout:
#   source/shared/fizzbuzz.{h,c}   portable FizzBuzz core (pure C99)
#   source/cli/main.c              CLI entry point
#   tests/model_test.c             host test (pipe-captured range output)
#   build/slices/fizzbuzz-<arch>   thin Mach-O per architecture
#   dist/fizzbuzz-macos            4-way fat macOS binary
#   dist/fizzbuzz-ios              2-way fat iOS binary (ad-hoc signed)
#

SHELL      := /bin/bash
BUILD_DIR  := build
SLICE_DIR  := $(BUILD_DIR)/slices
DIST_DIR   := dist

HOST_CC    ?= cc
HOST_CFLAGS := -std=c99 -O2 -Wall -Wextra

FIZZ_SRC   := source/shared/fizzbuzz.c
FIZZ_HDR   := source/shared/fizzbuzz.h
MAIN_SRC   := source/cli/main.c
TEST_SRC   := tests/model_test.c

# ---------------------------------------------------------------------------
# Toolchain environment (set by CI; see .github/workflows/build.yml).
# Each variable is optional — a missing one makes the slice fail clearly at
# run time (and is reported by `make -n` via the guard echo).
# ---------------------------------------------------------------------------
#
# ppc  (danupsher/tiger-ppc-builds v1.3, self-contained, 10.4u SDK inside)
PPC_XC     ?=
PPC_CC     ?= $(PPC_XC)/bin/ppc-tiger-gcc
PPC_SDK    ?= $(PPC_XC)/sdk/MacOSX10.4u.sdk
PPC_EXTRA  ?= -mmacosx-version-min=10.4
PPC_MINOS  := 10.4
#
# i386 (osxcross-1.1, MacOSX10.5 SDK)
I386_CC    ?=
I386_SDK   ?=
I386_MINOS := 10.5
#
# x86_64 / arm64 (osxcross master "stable", MacOSX11.3 SDK)
X64_CC     ?=
ARM_MAC_CC ?=
MAC_SDK_NEW ?=
X64_MINOS  := 10.9
ARM_MAC_MINOS := 11.0
#
# armv7 / arm64 iOS (cctools-port ios toolchain, iPhoneOS8.4 SDK)
IOS_CC     ?=
IOS_SDK    ?=
IOS_BIN    ?=
IOS_ARCH   ?=
IOS_ARMV7_MINOS := 5.0
IOS_ARM64_MINOS := 7.0
#
# Binutils
LIPO       ?= lipo
VTOOL      ?= vtool
OTOOL      ?= otool
LDID       ?= ldid

# ---------------------------------------------------------------------------
# Host test (always available)
# ---------------------------------------------------------------------------
.PHONY: test-host
test-host:
	@mkdir -p $(BUILD_DIR)
	@echo "== host test: $(HOST_CC) $(HOST_CFLAGS) -Isource/shared $(TEST_SRC) $(FIZZ_SRC)"
	$(HOST_CC) $(HOST_CFLAGS) -Isource/shared -o $(BUILD_DIR)/model_test $(TEST_SRC) $(FIZZ_SRC)
	$(BUILD_DIR)/model_test

# ---------------------------------------------------------------------------
# Slice helpers
# ---------------------------------------------------------------------------
# guard-tool <path> <label> <envvar> — run-time check: print a clear error
# and fail the target if <path> is empty or the file does not exist.
# Implemented as a recipe (not $(error)) so `make -n` still prints the plan.
define guard-tool
	@if [ -z "$(1)" ] || [ ! -e "$(1)" ]; then \
		echo "ERROR: toolchain for $(2) not found (env $(3) = '$(1)')." >&2; \
		echo "       Run in CI (all toolchains staged under toolchain/)" >&2; \
		echo "       or export $(3) to point at the compiler." >&2; \
		exit 1; \
	fi
endef

# slice-rule <arch> <cc> <sdk> <extra-flags>
# Compiles fizzbuzz.c + main.c into $(SLICE_DIR)/fizzbuzz-<arch>.
define slice-rule
	@mkdir -p $(SLICE_DIR)
	@echo "== slice $(1): $(2) $(4) -O2 -std=c99 -isysroot $(3) -o $(SLICE_DIR)/fizzbuzz-$(1) $(FIZZ_SRC) $(MAIN_SRC)"
	$(2) $(4) -O2 -std=c99 -Wall -Wextra -isysroot $(3) -o $(SLICE_DIR)/fizzbuzz-$(1) $(FIZZ_SRC) $(MAIN_SRC)
endef

.PHONY: slices slice-ppc slice-i386 slice-x86_64 slice-arm64-mac slice-armv7-ios slice-arm64-ios
slices: slice-ppc slice-i386 slice-x86_64 slice-arm64-mac slice-armv7-ios slice-arm64-ios

# --- ppc (macOS 10.4) -------------------------------------------------------
slice-ppc:
	$(call guard-tool,$(PPC_CC),ppc,PPC_CC)
	$(call guard-tool,$(PPC_SDK),ppc-sdk,PPC_SDK)
	$(call slice-rule,ppc,$(PPC_CC),$(PPC_SDK),$(PPC_EXTRA))

# --- i386 (macOS 10.5) ------------------------------------------------------
slice-i386:
	$(call guard-tool,$(I386_CC),i386,I386_CC)
	$(call guard-tool,$(I386_SDK),i386-sdk,I386_SDK)
	$(call slice-rule,i386,$(I386_CC),$(I386_SDK),-mmacosx-version-min=$(I386_MINOS))

# --- x86_64 (macOS 10.9) ----------------------------------------------------
slice-x86_64:
	$(call guard-tool,$(X64_CC),x86_64,X64_CC)
	$(call guard-tool,$(MAC_SDK_NEW),mac-sdk-11.3,MAC_SDK_NEW)
	$(call slice-rule,x86_64,$(X64_CC),$(MAC_SDK_NEW),-mmacosx-version-min=$(X64_MINOS))

# --- arm64 (macOS 11.0) -----------------------------------------------------
slice-arm64-mac:
	$(call guard-tool,$(ARM_MAC_CC),arm64-mac,ARM_MAC_CC)
	$(call guard-tool,$(MAC_SDK_NEW),mac-sdk-11.3,MAC_SDK_NEW)
	$(call slice-rule,arm64-mac,$(ARM_MAC_CC),$(MAC_SDK_NEW),-mmacosx-version-min=$(ARM_MAC_MINOS))

# --- armv7 (iOS 5.0) --------------------------------------------------------
slice-armv7-ios:
	$(call guard-tool,$(IOS_CC),armv7-ios,IOS_CC)
	$(call guard-tool,$(IOS_SDK),ios-sdk,IOS_SDK)
	@mkdir -p $(SLICE_DIR)
	@echo "== slice armv7-ios: $(IOS_CC) -arch armv7 -miphoneos-version-min=$(IOS_ARMV7_MINOS) -O2 -std=c99 -isysroot $(IOS_SDK) -o $(SLICE_DIR)/fizzbuzz-armv7-ios $(FIZZ_SRC) $(MAIN_SRC)"
	$(IOS_CC) -arch armv7 -miphoneos-version-min=$(IOS_ARMV7_MINOS) -O2 -std=c99 -Wall -Wextra -isysroot $(IOS_SDK) -o $(SLICE_DIR)/fizzbuzz-armv7-ios $(FIZZ_SRC) $(MAIN_SRC)

# --- arm64 (iOS 7.0) --------------------------------------------------------
slice-arm64-ios:
	$(call guard-tool,$(IOS_CC),arm64-ios,IOS_CC)
	$(call guard-tool,$(IOS_SDK),ios-sdk,IOS_SDK)
	@mkdir -p $(SLICE_DIR)
	@echo "== slice arm64-ios: $(IOS_CC) -arch arm64 -miphoneos-version-min=$(IOS_ARM64_MINOS) -O2 -std=c99 -isysroot $(IOS_SDK) -o $(SLICE_DIR)/fizzbuzz-arm64-ios $(FIZZ_SRC) $(MAIN_SRC)"
	$(IOS_CC) -arch arm64 -miphoneos-version-min=$(IOS_ARM64_MINOS) -O2 -std=c99 -Wall -Wextra -isysroot $(IOS_SDK) -o $(SLICE_DIR)/fizzbuzz-arm64-ios $(FIZZ_SRC) $(MAIN_SRC)

# ---------------------------------------------------------------------------
# Fat binaries
# ---------------------------------------------------------------------------
.PHONY: mac-fat
mac-fat: slice-ppc slice-i386 slice-x86_64 slice-arm64-mac
	@mkdir -p $(DIST_DIR)
	@echo "== lipo -create ppc i386 x86_64 arm64 -> $(DIST_DIR)/fizzbuzz-macos"
	$(LIPO) -create -arch ppc $(SLICE_DIR)/fizzbuzz-ppc \
		-arch i386 $(SLICE_DIR)/fizzbuzz-i386 \
		-arch x86_64 $(SLICE_DIR)/fizzbuzz-x86_64 \
		-arch arm64 $(SLICE_DIR)/fizzbuzz-arm64-mac \
		-output $(DIST_DIR)/fizzbuzz-macos
	$(LIPO) -info $(DIST_DIR)/fizzbuzz-macos

.PHONY: ios-fat
ios-fat: slice-armv7-ios slice-arm64-ios
	@mkdir -p $(DIST_DIR)
	@echo "== lipo -create armv7 arm64 -> $(DIST_DIR)/fizzbuzz-ios"
	$(LIPO) -create -arch armv7 $(SLICE_DIR)/fizzbuzz-armv7-ios \
		-arch arm64 $(SLICE_DIR)/fizzbuzz-arm64-ios \
		-output $(DIST_DIR)/fizzbuzz-ios
	$(LIPO) -info $(DIST_DIR)/fizzbuzz-ios
	@# Ad-hoc sign. Prefer ldid; fall back to codesign; warn if neither.
	@if command -v $(LDID) >/dev/null 2>&1; then \
		echo "== ad-hoc sign (ldid): $(LDID) -S $(DIST_DIR)/fizzbuzz-ios"; \
		$(LDID) -S $(DIST_DIR)/fizzbuzz-ios; \
	elif command -v codesign >/dev/null 2>&1; then \
		echo "== ad-hoc sign (codesign): codesign --sign - $(DIST_DIR)/fizzbuzz-ios"; \
		codesign --sign - $(DIST_DIR)/fizzbuzz-ios; \
	else \
		echo "== WARNING: no ad-hoc signer (ldid/codesign) available; leaving $(DIST_DIR)/fizzbuzz-ios unsigned"; \
	fi

.PHONY: all
all: mac-fat ios-fat
	@echo "== all: both fat binaries produced"

# ---------------------------------------------------------------------------
# Validate: lipo -info + per-slice min-OS, written to build/manifest.txt
# ---------------------------------------------------------------------------
.PHONY: validate
validate: mac-fat ios-fat
	@mkdir -p $(BUILD_DIR)
	@echo "== validate: writing $(BUILD_DIR)/manifest.txt"
	@{ \
		echo "fizzbuzz build manifest"; \
		echo "======================="; \
		echo ""; \
		echo "macOS Quad-Fat: $(DIST_DIR)/fizzbuzz-macos"; \
		$(LIPO) -info $(DIST_DIR)/fizzbuzz-macos; \
		echo ""; \
		echo "iOS FAT: $(DIST_DIR)/fizzbuzz-ios"; \
		$(LIPO) -info $(DIST_DIR)/fizzbuzz-ios; \
		echo ""; \
		VTOOL="$(VTOOL)" OTOOL="$(OTOOL)" PPC_XC="$(PPC_XC)" \
			bash scripts/report_minos.sh $(SLICE_DIR); \
		echo ""; \
		echo "Sizes:"; \
		ls -l $(DIST_DIR)/fizzbuzz-macos $(DIST_DIR)/fizzbuzz-ios; \
	} | tee $(BUILD_DIR)/manifest.txt

# ---------------------------------------------------------------------------
# Clean
# ---------------------------------------------------------------------------
.PHONY: clean
clean:
	rm -rf $(BUILD_DIR) $(DIST_DIR)
