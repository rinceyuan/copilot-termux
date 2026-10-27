#!/data/data/com.termux/files/usr/bin/bash
set -eu

# Run on ARM64 Android: no Copilot session, credentials or network required.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT
export LD_LIBRARY_PATH="$TEST_ROOT${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

clang -O2 -Wall -Wextra -Werror -shared -fPIC \
  -Wl,--no-undefined,-soname,libspawn_xlate.so \
  -o "$TEST_ROOT/libspawn_xlate.so" "$REPO_ROOT/shim/spawn_xlate.c"
clang -O2 -Wall -Wextra -Werror -o "$TEST_ROOT/test_spawn_xlate" \
  "$REPO_ROOT/scripts/test_spawn_xlate.c" -L"$TEST_ROOT" -lspawn_xlate
"$TEST_ROOT/test_spawn_xlate" "$TEST_ROOT"

clang -O2 -Wall -Wextra -Werror -shared -fPIC -fvisibility=hidden \
  -Wl,--no-undefined,--exclude-libs,ALL -o "$TEST_ROOT/libtls_xlate.so" \
  "$REPO_ROOT/shim/tls_xlate.c" -ldl
for module in cli-native runtime; do
  cp "$TEST_ROOT/libtls_xlate.so" "$TEST_ROOT/libtls_xlate-$module.so"
  clang -O2 -Wall -Wextra -Werror -shared -fPIC -fno-emulated-tls \
    -o "$TEST_ROOT/$module.node" "$REPO_ROOT/scripts/test_tls_module.c" \
    -L"$TEST_ROOT" -Wl,--no-as-needed "-l:libtls_xlate-$module.so"
done
clang -O2 -Wall -Wextra -Werror -o "$TEST_ROOT/test_tls_xlate" \
  "$REPO_ROOT/scripts/test_tls_xlate.c" -ldl
"$TEST_ROOT/test_tls_xlate" "$TEST_ROOT/cli-native.node" "$TEST_ROOT/runtime.node"
