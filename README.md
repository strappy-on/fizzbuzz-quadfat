# fizzbuzz-quadfat

A tiny C CLI called **fizzbuzz** that takes **no arguments**, runs FizzBuzz
from **0 to 1000 inclusive**, and prints the results to stdout — one line per
number. The number is replaced by:

- `Fizz`      if divisible by 3
- `Buzz`      if divisible by 5
- `FizzBuzz`  if divisible by both (e.g. 0, 15, 30, …)
- the number itself otherwise

`0` is divisible by both 3 and 5, so the first line printed is `FizzBuzz`.

The project ships **two deliverable universal (fat) Mach-O binaries**, both
built and validated entirely in GitHub Actions on an x86_64 Linux runner —
no Mac required:

| Deliverable | File | Architectures (exact) | Per-slice min-OS |
|---|---|---|---|
| macOS Quad-Fat | `fizzbuzz-macos` | `ppc`, `i386`, `x86_64`, `arm64` | 10.4, 10.5, 10.9, 11.0 |
| iOS FAT (ad-hoc signed) | `fizzbuzz-ios` | `armv7`, `arm64` | 5.0, 7.0 |

## Why "Quad-Fat" and these min-OS values

"Quad-Fat for OS X 10.4+" means a single fat binary with **four** architecture
slices, the oldest of which (ppc) runs on Mac OS X 10.4 Tiger. The per-slice
deployment floors reflect the earliest macOS/iOS that actually supports each
CPU:

- **ppc** — 10.4 (the first Mac OS X; PowerPC was the original Mac CPU)
- **i386** — 10.5 (Leopard; 32-bit Intel)
- **x86_64** — 10.9 (Mavericks; 64-bit Intel became default)
- **arm64** — 11.0 (Big Sur; first Apple Silicon Mac)

"iOS 5+ FAT" means a fat binary with **two** slices, the oldest (armv7) running
on iOS 5:

- **armv7** — 5.0 (iOS 5; 32-bit ARM)
- **arm64** — 7.0 (iOS 7; 64-bit ARM)

## Why this is non-trivial

Modern Apple toolchains (Xcode 12+, and the current `osxcross` master) have
**dropped PowerPC and 32-bit iOS (armv7)**. Building those slices from scratch
requires the legacy cross-compilation toolchains below, all of which run on
x86_64 Linux (no Mac needed):

| Slice | Toolchain | Why |
|---|---|---|
| ppc | [danupsher/tiger-ppc-builds](https://github.com/danupsher/tiger-ppc-builds) v1.3 (self-contained: GCC 15 + ld64 + cctools + 10.4u SDK) | PowerPC is no longer supported by any modern toolchain; this is a prebuilt, self-contained GCC/ld64/cctools bundle targeting `powerpc-apple-darwin8`. |
| i386 | [osxcross](https://github.com/tpoechtrager/osxcross) `osxcross-1.1` branch, built with the MacOSX10.5 SDK | The last osxcross branch that still produces a 32-bit Intel (darwin9) target. |
| x86_64, arm64 (mac) | osxcross `master`, "stable" flavor, `ENABLE_ARCHS="x86_64 arm64"`, MacOSX11.3 SDK | Modern 64-bit targets. |
| armv7, arm64 (iOS) | [cctools-port](https://github.com/tpoechtrager/cctools-port) `usage_examples/ios_toolchain`, built against the iPhoneOS8.4 SDK, using the system `clang` | armv7 (32-bit iOS) was dropped from Xcode 12+; cctools-port's ld64 still links it. |

## Repository layout

```
source/shared/fizzbuzz.h    Portable FizzBuzz core (pure C99)
source/shared/fizzbuzz.c    Implementation
source/cli/main.c           CLI entry point (no args)
tests/model_test.c          Host test (pipe-captured range output)
Makefile                    Toolchain-agnostic build (host test + Apple slices)
.github/workflows/build.yml GitHub Actions: 4 toolchain jobs + build + test
LICENSE                     MIT
```

All generated output lives under `build/` and `dist/` (both gitignored).

## Building

### Host test (always works)

```sh
make test-host
```

Compiles `tests/model_test.c` + `source/shared/fizzbuzz.c` with the host `cc`
and runs it. The test verifies the label function against known values,
captures the full `fizzbuzz_print_range(0, 1000)` output through a pipe, and
checks it emits exactly 1001 lines with the correct first/last/mid lines.
Prints `ALL TESTS PASSED` on success.

### Apple slices (require CI toolchains)

The Apple slices require the cross toolchains that only exist in CI. Locally,
each slice target fails with a clear message (e.g. `toolchain for ppc not
found; run in CI or set PPC_CC`). In CI, the workflow stages the toolchains
under `toolchain/`, exports the environment variables the Makefile reads, and
runs:

```sh
make all        # all 6 slices + both fat binaries
make validate   # lipo -info + per-slice min-OS manifest -> build/manifest.txt
```

The Makefile is **toolchain-agnostic**: every slice reads its compiler/SDK from
an environment variable (`PPC_CC`/`PPC_SDK`, `I386_CC`/`I386_SDK`,
`X64_CC`/`ARM_MAC_CC`/`MAC_SDK_NEW`, `IOS_CC`/`IOS_SDK`), so the same Makefile
drives both local and CI builds.

## How CI works

The workflow (`.github/workflows/build.yml`) has six jobs, all on
`ubuntu-latest` (x86_64 Linux), with `timeout-minutes: 45`:

```
toolchain-ppc  ─┐
toolchain-i386 ─┤
toolchain-mac  ─┼──>  build  ──>  test
toolchain-ios  ─┘
```

1. **toolchain-ppc** — downloads the danupsher PPC cross-compiler tarball,
   extracts it, verifies `ppc-ld64-gcc --version`, caches `toolchain/`, and
   uploads artifact `ppc-toolchain`.
2. **toolchain-i386** — installs osxcross deps, clones osxcross
   (`osxcross-1.1`), downloads the MacOSX10.5 SDK from the secret, builds
   osxcross, verifies `i386-apple-darwin9-clang`, caches, and uploads
   `i386-toolchain` + `sdk-10.5`.
3. **toolchain-mac** — clones osxcross (`master`), downloads the MacOSX11.3
   SDK from the secret, builds with `BUILD_FLAVOR=stable ENABLE_ARCHS="x86_64
   arm64"`, verifies both clangs, caches, and uploads `mac-toolchain` +
   `sdk-11.3`.
4. **toolchain-ios** — installs cctools deps, clones cctools-port, builds
   apple-libtapi, runs `usage_examples/ios_toolchain/build.sh` with the
   iPhoneOS8.4 SDK, verifies the produced `arm-apple-darwin11-clang` and that
   a tiny armv7 program links (proving armv7 linking works), caches, and
   uploads `ios-toolchain` + `sdk-iphoneos-8.4`.
5. **build** — downloads all toolchain + SDK artifacts, assembles `toolchain/`,
   resolves the toolchain paths, exports the env vars, runs `make all` then
   `make validate`, **asserts the exact arch sets** (mac has exactly
   ppc/i386/x86_64/arm64; ios has exactly armv7/arm64) by reading each slice's
   Mach-O `cputype`, prints per-slice min-OS, writes `build/manifest.txt`, and
   uploads `fizzbuzz-macos`, `fizzbuzz-ios`, `build-manifest`.
6. **test** — downloads the fat artifacts, runs `make test-host` (the native
   host test), re-validates the downloaded fat binaries (arch sets via
   `cputype`, non-zero size), and prints a final PASS/FAIL summary. The job
   fails if the host test fails or any fat binary's arch set is wrong.

Each toolchain download/build step prints exactly what it is doing, and the
build job echoes every slice compile command.

### Caching

Toolchain builds are slow on first run. Each toolchain job caches its output
(`actions/cache/save@v4`) keyed by toolchain + SDK version, so re-runs are
fast. The `build` and `test` jobs re-download the toolchain artifacts rather
than relying on the cache (artifacts are the source of truth).

## Required repository secrets

The workflow reads three repo secrets — the SDK download URLs. **Names only;
values are secret and must not be pasted anywhere:**

| Secret name | What it points to |
|---|---|
| `ALTIVEC_SDK_MACOS_105_URL` | `MacOSX10.5.sdk.tar.xz` |
| `ALTIVEC_SDK_MACOS_113_URL` | `MacOSX11.3.sdk.tar.xz` |
| `ALTIVEC_SDK_IPHONEOS_84_URL` | `iPhoneOS8.4.sdk.tar.gz` |

Set them with the `gh` CLI:

```sh
gh secret set ALTIVEC_SDK_MACOS_105_URL    --body "<url>" --repo <owner>/fizzbuzz-quadfat
gh secret set ALTIVEC_SDK_MACOS_113_URL    --body "<url>" --repo <owner>/fizzbuzz-quadfat
gh secret set ALTIVEC_SDK_IPHONEOS_84_URL  --body "<url>" --repo <owner>/fizzbuzz-quadfat
```

## Running the binaries

- **macOS** — `fizzbuzz-macos` is a universal binary; the OS picks the native
  slice. It runs on any PowerPC, 32-bit Intel, 64-bit Intel, or Apple Silicon
  Mac that meets the relevant slice's min-OS (10.4/10.5/10.9/11.0).
- **iOS** — `fizzbuzz-ios` is a 2-way fat binary (armv7 + arm64), **ad-hoc
  signed** (`ldid -S` in CI). Install/sideload it to a jailbroken device or
  simulator; the ad-hoc signature is for local testing, not App Store
  distribution.

Expected `lipo -info` output:

```
$ lipo -info fizzbuzz-macos
Architectures in the fat file: fizzbuzz-macos are: ppc i386 x86_64 arm64

$ lipo -info fizzbuzz-ios
Architectures in the fat file: fizzbuzz-ios are: armv7 arm64
```

(Note: some `lipo` builds label a PowerPC *ALL*-subtype slice `ppc603` rather
than `ppc`; the CI validation therefore reads the Mach-O `cputype` (18 =
PowerPC) directly to confirm the exact arch set.)

## License

MIT — see [LICENSE](LICENSE).
