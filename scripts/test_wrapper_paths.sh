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
    echo " (NEEDED) Shared library: [libpthread_xlate.so]"
  fi
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
    return 1
  fi
  mkdir -p "$3/prebuilds/linuxmusl-arm64"
  : > "$3/index.js"
  : > "$3/prebuilds/linuxmusl-arm64/runtime.node"
}

exec() {
  printf '%s\n' "$@" > "$EXEC_LOG"
}

export -f npm readelf python3 exec

run_case() (
  scenario="$1"
  case_root="$TEST_ROOT/$scenario"
  export HOME="$case_root/home with spaces" PREFIX="$case_root/termux"
  export EXEC_LOG="$case_root/exec.log" NPM_RESULT=success
  unset LD_PRELOAD LD_LIBRARY_PATH
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
      npm-*|missing-entry)
        echo "FAIL: $scenario unexpectedly succeeded" >&2
        cat "$case_root/wrapper.log" >&2
        exit 1
        ;;
    esac
    printf '%s\n' /data/data/com.termux/files/usr/bin/node \
      "$expected_entry" -p "hello world" > "$case_root/expected.log"
    cmp "$case_root/expected.log" "$EXEC_LOG"
  else
    case "$scenario" in
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

for scenario in default-sea custom-split home-legacy npm-failure npm-empty missing-entry; do
  run_case "$scenario"
  echo "PASS: $scenario"
done
