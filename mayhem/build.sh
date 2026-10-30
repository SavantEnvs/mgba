#!/usr/bin/env bash
#
# mayhem/build.sh — build mGBA's fuzz harnesses (sanitized, DWARF 3) AND its test suite (normal flags).
# Runs inside the commit image (mayhem/Dockerfile) as `mayhem` in /mayhem; safe to re-run offline.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

# Features shared by both builds: the library only needs libpng/zlib/libzip/libelf from apt (lzma is in-tree).
COMMON_CMAKE=(
  -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_COMPILER="$CC"
  -DBUILD_QT=OFF -DBUILD_SDL=OFF -DBUILD_GL=OFF -DBUILD_GLES2=OFF -DBUILD_GLES3=OFF
  -DUSE_FFMPEG=OFF -DUSE_EPOXY=OFF -DUSE_SQLITE3=OFF -DUSE_LUA=OFF -DUSE_JSON_C=OFF
  -DUSE_FREETYPE=OFF -DUSE_DISCORD_RPC=OFF -DUSE_EDITLINE=OFF -DUSE_MINIZIP=OFF
  -DBUILD_STATIC=ON -DBUILD_SHARED=OFF -DCMAKE_EXPORT_COMPILE_COMMANDS=ON
)

# 1) The sanitized, SanCov-instrumented library (fuzzer-no-link: coverage without the engine).
#    -fno-sanitize=alignment: upstream's LOAD_/STORE_ macros (common.h) deliberately do unaligned 16/32/64-bit
#    accesses into the packed save-state struct on little-endian hosts, so every state load trips UBSan's
#    alignment check; every other UBSan check and ASan stay on and halting.
cmake -S . -B build-fuzz "${COMMON_CMAKE[@]}" -DBUILD_TEST=ON \
  -DCMAKE_PROJECT_INCLUDE="$SRC/mayhem/relax_bool.cmake" \
  -DCMAKE_C_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link -fno-sanitize=alignment"
cmake --build build-fuzz --target mgba -j"$MAYHEM_JOBS"

# The feature -D/-I flags the library was configured with (struct layouts depend on them).
mapfile -t LIB_FLAGS < <(python3 - <<'PY'
import json, shlex
for e in json.load(open("build-fuzz/compile_commands.json")):
    if e["file"].endswith("tbl-fuzz-main.c"):
        for t in shlex.split(e["command"]):
            if t.startswith(("-D", "-I")):
                print(t)
PY
)
LINK_LIBS=(build-fuzz/libmgba.a -lpng -lzip -lz -lelf -lm -lpthread)

# 2) Harnesses: libFuzzer binary + standalone run-once reproducer, with LeakSanitizer turned off at build time.
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c mayhem/lsan_off.cc -o /tmp/lsan_off.o
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c -x c "$STANDALONE_FUZZ_MAIN" -o /tmp/standalone_main.o

build_harness() {  # <name> <source> [extra -D]
  local name="$1" src="$2"; shift 2
  $CC $SANITIZER_FLAGS $DEBUG_FLAGS "${LIB_FLAGS[@]}" "$@" -fsanitize=fuzzer-no-link -c "$src" -o "/tmp/$name.o"
  $CC $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE "/tmp/$name.o" /tmp/lsan_off.o "${LINK_LIBS[@]}" -o "/mayhem/$name"
  $CC $SANITIZER_FLAGS $DEBUG_FLAGS /tmp/standalone_main.o "/tmp/$name.o" /tmp/lsan_off.o "${LINK_LIBS[@]}" -o "/mayhem/$name-standalone"
}
build_harness fuzz_gba_rom   mayhem/fuzz_rom.c   -DFUZZ_GBA
build_harness fuzz_gb_rom    mayhem/fuzz_rom.c   -DFUZZ_GB
build_harness fuzz_gba_state mayhem/fuzz_state.c -DFUZZ_GBA
build_harness fuzz_gb_state  mayhem/fuzz_state.c -DFUZZ_GB
build_harness fuzz_tbl       mayhem/fuzz_tbl.c

# 3) The project's own test suite (cmocka unit tests + the "cinema" screenshot-baseline suite),
#    NORMAL flags, no sanitizers, so mayhem/test.sh only runs it.
cmake -S . -B build-tests "${COMMON_CMAKE[@]}" -DBUILD_SUITE=ON -DBUILD_CINEMA=ON \
  -DCMAKE_C_FLAGS="$COVERAGE_FLAGS" -DCMAKE_EXE_LINKER_FLAGS="$COVERAGE_FLAGS"
cmake --build build-tests -j"$MAYHEM_JOBS"
