#!/usr/bin/env bash
#
# mosquitto/mayhem/build.sh (mining layer) — builds the broker's --test-config path as a sanitized
# libFuzzer target (+ a standalone reproducer), plus mosquitto's own lib unit tests with normal flags.
#
# broker_fuzz_test_config writes the fuzz input to a scratch file and calls the broker's fuzz-only main
# (WITH_FUZZING) as `mosquitto --test-config -c <file>`: the config parser runs, then the config is
# cleaned up. The broker archive is compiled WITH $SANITIZER_FLAGS so the parser (src/conf.c) is
# instrumented.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# `=` (not `:=`) so an explicit empty --build-arg SANITIZER_FLAGS= builds with NO sanitizers.
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
# DEBUG_FLAGS: DWARF-3 so Mayhem triage can read symbols (clang-19 default is DWARF-5; §6.2 item 10).
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${STANDALONE_FUZZ_MAIN:=/opt/mayhem/StandaloneFuzzTargetMain.c}"
: "${MAYHEM_JOBS:=$(nproc)}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS

cd "$SRC"

# ── 1) mosquitto's lib unit tests (test/unit/mosq_test, CUnit) with NORMAL flags, first, so the
#       sanitized build below starts from clean object files. test.sh only RUNS the binary. ─────────
echo "=== building lib unit-test suite (normal flags) ==="
env -u CFLAGS -u CXXFLAGS -u SANITIZER_FLAGS \
  make WITH_STATIC_LIBRARIES=yes WITH_DOCS=no WITH_EDITLINE=no -C test/unit mosq_test -j"$MAYHEM_JOBS"
ls -la "$SRC/test/unit/mosq_test"
env -u CFLAGS -u CXXFLAGS -u SANITIZER_FLAGS make -C lib clean
env -u CFLAGS -u CXXFLAGS -u SANITIZER_FLAGS make -C src clean

# ── 2) Build mosquitto's lib + broker static archive WITH sanitizers. WITH_FUZZING=yes implies static
#       libs + -DWITH_FUZZING (the broker's main becomes mosquitto_fuzz_main). ──────────────────────
MK_ARGS=(WITH_STATIC_LIBRARIES=yes WITH_DOCS=no WITH_FUZZING=yes WITH_EDITLINE=no)
export CFLAGS="-Wall -O2 $SANITIZER_FLAGS $DEBUG_FLAGS"
export CXXFLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS"

make "${MK_ARGS[@]}" -C src mosquitto_broker.a -j"$MAYHEM_JOBS"

BROKER_A="$SRC/src/mosquitto_broker.a"
ls -la "$BROKER_A"

# ── 3) The harness twice: libFuzzer (-> /mayhem/<name>) + standalone reproducer (-> -standalone). ──
HARNESS_DIR="$SRC/mayhem/harnesses"
BUILD="$SRC/mayhem-build"
mkdir -p "$BUILD"

HARNESS_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS -Wall -pthread -I$SRC/include"
LINK_LIBS="-lssl -lcrypto -lcjson -lm"

$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$BUILD/standalone_main.o"
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o "$BUILD/lsan_off.o"

harness=broker_fuzz_test_config
$CXX $HARNESS_FLAGS "$HARNESS_DIR/$harness.cpp" "$BUILD/lsan_off.o" \
    "$BROKER_A" $LIB_FUZZING_ENGINE $LINK_LIBS -o "/mayhem/$harness"
$CXX $HARNESS_FLAGS "$HARNESS_DIR/$harness.cpp" "$BUILD/lsan_off.o" \
    "$BUILD/standalone_main.o" "$BROKER_A" $LINK_LIBS -o "/mayhem/$harness-standalone"
echo "built $harness (+ standalone)"
