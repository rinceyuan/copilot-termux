#!/data/data/com.termux/files/usr/bin/bash
set -eu

# Run the real wrapper with fake packages; never execute an Android binary.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT

npm() {
  if [ "$*" != "root -g" ]; then
    echo "Unexpected npm invocation: $*" >&2
    return 1
  fi
  case "$NPM_RESULT" in
    failure) echo "Mock npm configuration error" >&2; return 1 ;;
    empty) return 0 ;;
    success) printf '%s\n' "$NPM_TEST_ROOT" ;;
  esac
}

readelf() {
  if [ "$1" = "-d" ]; then
    if [ -f "$2.needed" ]; then
      while IFS= read -r lib; do
        printf ' (NEEDED) Shared library: [%s]\n' "$lib"
      done < "$2.needed"
    else
      for lib in libm.so libdl.so libgai_xlate.so libpthread_xlate.so; do
        printf ' (NEEDED) Shared library: [%s]\n' "$lib"
      done
    fi
  fi
}

patchelf() {
  printf '%s\n' "$*" >> "$PATCHELF_LOG"
  case "$PATCH_BEHAVIOR" in
    failure) echo "Mock patchelf write failure" >&2; return 1 ;;
    noop) return 0 ;;
  esac
  case "$1" in
    --add-needed) printf '%s\n' "$2" >> "$3.needed" ;;
    --set-rpath) return 0 ;;
    *) echo "Unexpected patchelf invocation: $*" >&2; return 1 ;;
  esac
}

python3() {
  if [ "$1" = "-c" ]; then
    test "$3" = "$NPM_TEST_ROOT/@github/copilot-linuxmusl-arm64/package.json" || return 1
    echo "1.0.97"
    return 0
  fi
  test "$1" = "$HOME/.copilot-versions/shim/extract_sea.py" || return 1
  test "$2" = "$NPM_TEST_ROOT/@github/copilot-linuxmusl-arm64/copilot" || return 1
  if [ "$4" = "--check" ]; then
    test -f "$3/index.js" && test -d "$3/prebuilds" &&
      command grep -qx "$6" "$3/.sea-extracted-version"
    return $?
  fi
  mkdir -p "$3/prebuilds/linuxmusl-arm64"
  : > "$3/index.js"
  : > "$3/prebuilds/linuxmusl-arm64/runtime.node"
  printf '%s\n' "$5" > "$3/.sea-extracted-version"
}

exec() {
  if [ -n "${NATIVE_TEST_DIR:-}" ]; then
    for module in "$NATIVE_TEST_DIR"/*.node; do
      if ! command grep -qx libm.so "$module.needed"; then
        echo "dlopen failed: cannot locate symbol expf in $module" >&2
        return 1
      fi
    done
  fi
  printf '%s\n' "$@" > "$EXEC_LOG"
}

export -f npm readelf patchelf python3 exec

run_case() (
  scenario="$1"
  case_root="$TEST_ROOT/$scenario"
  export HOME="$case_root/home with spaces" PREFIX="$case_root/termux"
  export EXEC_LOG="$case_root/exec.log" NPM_RESULT=success
  export PATCHELF_LOG="$case_root/patchelf.log" PATCH_BEHAVIOR=success
  unset LD_PRELOAD LD_LIBRARY_PATH NATIVE_TEST_DIR
  mkdir -p "$HOME"

  case "$scenario" in
    default-sea)
      export NPM_TEST_ROOT="$PREFIX/lib/node_modules"
      package="$NPM_TEST_ROOT/@github/copilot-linuxmusl-arm64"
      mkdir -p "$package" "$HOME/.copilot-versions/shim"
      : > "$package/copilot"
      echo '{"version":"1.0.97"}' > "$package/package.json"
      : > "$HOME/.copilot-versions/shim/extract_sea.py"
      expected_entry="$HOME/.copilot-versions/sea-1.0.97/index.js"
      ;;
    custom-split)
      export NPM_TEST_ROOT="$HOME/custom npm/lib/node_modules"
      package="$NPM_TEST_ROOT/@github/copilot-linuxmusl-arm64"
      mkdir -p "$package/prebuilds/linuxmusl-arm64"
      : > "$package/index.js"
      : > "$package/prebuilds/linuxmusl-arm64/runtime.node"
      expected_entry="$package/index.js"
      ;;
    unpatched-sea|missing-math|patch-failure|patch-noop)
      export NPM_TEST_ROOT="$PREFIX/lib/node_modules"
      package="$NPM_TEST_ROOT/@github/copilot-linuxmusl-arm64"
      cached_app="$HOME/.copilot-versions/sea-1.0.97"
      export NATIVE_TEST_DIR="$cached_app/prebuilds/linuxmusl-arm64"
      mkdir -p "$package" "$NATIVE_TEST_DIR" "$HOME/.copilot-versions/shim"
      : > "$package/copilot"
      echo '{"version":"1.0.97"}' > "$package/package.json"
      : > "$cached_app/index.js"
      echo "1.0.97" > "$cached_app/.sea-extracted-version"
      for module in runtime cli-native; do
        : > "$NATIVE_TEST_DIR/$module.node"
        printf '%s\n' libc.so > "$NATIVE_TEST_DIR/$module.node.needed"
        if [ "$scenario" = "missing-math" ]; then
          printf '%s\n' libdl.so libgai_xlate.so libpthread_xlate.so \
            >> "$NATIVE_TEST_DIR/$module.node.needed"
        fi
      done
      for file in extract_sea.py rename_imports.py libgai_xlate.so libpthread_xlate.so; do
        : > "$HOME/.copilot-versions/shim/$file"
      done
      case "$scenario" in
        patch-*) export PATCH_BEHAVIOR="${scenario#patch-}" ;;
      esac
      expected_entry="$cached_app/index.js"
      ;;
    home-legacy)
      export NPM_TEST_ROOT="$HOME/.npm-global/lib/node_modules"
      package="$NPM_TEST_ROOT/@github/copilot"
      mkdir -p "$package"
      : > "$package/index.js"
      : > "$package/npm-loader.js"
      expected_entry="$package/npm-loader.js"
      ;;
    npm-failure|npm-empty)
      export NPM_RESULT="${scenario#npm-}"
      # A stale installation must not hide an npm discovery error.
      package="$HOME/.npm-global/lib/node_modules/@github/copilot"
      mkdir -p "$package"
      : > "$package/index.js"
      ;;
    missing-entry)
      export NPM_TEST_ROOT="$PREFIX/lib/node_modules"
      mkdir -p "$NPM_TEST_ROOT"
      ;;
  esac

  if bash "$REPO_ROOT/scripts/copilot-wrapper.sh" -p "hello world" \
      > "$case_root/wrapper.log" 2>&1; then
    case "$scenario" in
      npm-*|missing-entry|patch-*)
        echo "FAIL: $scenario unexpectedly succeeded" >&2
        cat "$case_root/wrapper.log" >&2
        exit 1
        ;;
    esac
    printf '%s\n' /data/data/com.termux/files/usr/bin/node \
      "$expected_entry" -p "hello world" > "$case_root/expected.log"
    cmp "$case_root/expected.log" "$EXEC_LOG"
    if [ "$scenario" = "missing-math" ] || [ "$scenario" = "unpatched-sea" ]; then
      for module in runtime cli-native; do
        for lib in libm.so libdl.so libgai_xlate.so libpthread_xlate.so; do
          test "$(command grep -cx "$lib" "$NATIVE_TEST_DIR/$module.node.needed")" = 1
        done
      done
      cp "$PATCHELF_LOG" "$case_root/first-patch.log"
      if ! bash "$REPO_ROOT/scripts/copilot-wrapper.sh" -p "hello world" \
          > "$case_root/relaunch.log" 2>&1; then
        cat "$case_root/relaunch.log" >&2
        exit 1
      fi
      cmp "$case_root/first-patch.log" "$PATCHELF_LOG"
      cmp "$case_root/expected.log" "$EXEC_LOG"
    fi
  else
    case "$scenario" in
      patch-*)
        command grep -q "ERROR: native runtime patch is incomplete" "$case_root/wrapper.log"
        ;;
      npm-*)
        command grep -q "ERROR: could not determine npm global modules directory" \
          "$case_root/wrapper.log"
        ;;
      missing-entry)
        command grep -q "ERROR: no copilot entry point found" "$case_root/wrapper.log"
        command grep -qF "$NPM_TEST_ROOT/@github/copilot/index.js" "$case_root/wrapper.log"
        ;;
      *)
        cat "$case_root/wrapper.log" >&2
        exit 1
        ;;
    esac
    test ! -e "$EXEC_LOG"
  fi
)

for scenario in default-sea custom-split home-legacy npm-failure npm-empty missing-entry \
                unpatched-sea missing-math patch-failure patch-noop; do
  run_case "$scenario"
  echo "PASS: $scenario"
done
