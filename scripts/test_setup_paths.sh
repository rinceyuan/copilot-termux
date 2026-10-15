#!/data/data/com.termux/files/usr/bin/bash
set -eu

# Exercise the real installer without installing packages or compiling addons.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT

pkg() {
  printf '%s\n' "$*" >> "$HOME/pkg.log"
  case "$*" in
    "update -y") : > "$HOME/.packages-updated" ;;
    "upgrade -y")
      if [ ! -f "$HOME/.packages-updated" ]; then
        echo "Package lists must be updated before upgrading" >&2
        return 1
      fi
      if [ "$PKG_UPGRADE_FAIL" = "1" ]; then
        echo "Mock package upgrade failure" >&2
        return 1
      fi
      : > "$HOME/.packages-upgraded"
      ;;
    "install "*)
      if [ ! -f "$HOME/.packages-upgraded" ]; then
        echo "Packages must be upgraded before installing dependencies" >&2
        return 1
      fi
      ;;
  esac
  if [ "$*" = "install -y libsecret" ]; then
    if [ "$LIBSECRET_INSTALL_FAIL" = "1" ]; then
      echo "Mock libsecret installation failure" >&2
      return 1
    fi
    : > "$HOME/.libsecret-installed"
  fi
  return 0
}
uname() { echo aarch64; }
node() { return 0; }
python3() { return 0; }
patchelf() { return 0; }
llvm-objcopy() { return 0; }

npm() {
  case "$*" in
    "root -g") echo "$HOME/npm/lib/node_modules" ;;
    "list -g @github/copilot") echo "@github/copilot@1.0.91" ;;
    "view @github/copilot version") echo "1.0.97" ;;
    "ls -g --depth=0") echo "" ;;
    "install node-pty")
      mkdir -p node_modules/node-pty/build/Release
      echo "rebuilt pty" > node_modules/node-pty/build/Release/pty.node
      ;;
    "install keytar --ignore-scripts")
      mkdir -p node_modules/keytar/build/Release
      ;;
    "run build")
      if [ ! -f "$HOME/.libsecret-installed" ]; then
        echo "libsecret must be installed before building keytar" >&2
        return 1
      fi
      echo "built keytar" > build/Release/keytar.node
      ;;
    "install -g @github/copilot" | \
    "install -g @github/copilot@1.0.97 --force" | \
    "install node-addon-api@latest --save-dev" | \
    "install sharp" | \
    "install @teddyzhu/clipboard --ignore-scripts")
      echo "Mock npm: $*"
      ;;
    *)
      echo "Unexpected npm invocation: $*" >&2
      return 1
      ;;
  esac
}

clang() {
  local source="${@: -1}"
  if [ ! -f "$source" ]; then
    echo "Missing compiler input: $source" >&2
    return 1
  fi
  while [ "$#" -gt 0 ]; do
    if [ "$1" = "-o" ]; then
      : > "$2"
      return 0
    fi
    shift
  done
  echo "Missing clang output argument" >&2
  return 1
}

export -f pkg uname node python3 patchelf llvm-objcopy npm clang

run_case() (
  mode="$1"
  invocation="$2"
  export LIBSECRET_INSTALL_FAIL="${3:-0}"
  export PKG_UPGRADE_FAIL="${4:-0}"
  case_root="$TEST_ROOT/$mode-$invocation-$LIBSECRET_INSTALL_FAIL-$PKG_UPGRADE_FAIL"
  repo="$case_root/repo with spaces"
  export HOME="$case_root/home with spaces"
  export PREFIX="$HOME/usr" TERMUX_VERSION="test"
  unset CDPATH COPILOT_MAX_VERSION COPILOT_ALLOW_BROKEN
  install_root="$HOME/npm/lib/node_modules/@github/copilot"
  mkdir -p "$repo/shim" "$repo/scripts" "$install_root/prebuilds/android-arm64"
  cp "$REPO_ROOT/setup.sh" "$repo/setup.sh"

  for file in bionic_shim.c strip_verneed.py patch_js.py gai_xlate.c \
              pthread_xlate.c rename_imports.py patch_mouse.py extract_sea.py; do
    printf 'fixture: %s\n' "$file" > "$repo/shim/$file"
  done
  printf '#!%s\necho "GitHub Copilot CLI 1.0.97"\n' "$(command -v bash)" \
    > "$repo/scripts/copilot-wrapper.sh"
  printf '#!%s\n# TUI harness fixture\n' "$(command -v bash)" \
    > "$repo/scripts/pty_tui_test.py"

  set --
  if [ "$mode" != "install" ]; then
    set -- --update
  fi
  if [ "$mode" = "update-backup" ]; then
    echo "existing pty" > "$install_root/prebuilds/android-arm64/pty.node"
  fi

  case "$invocation" in
    local)
      cd "$repo"
      entrypoint="./setup.sh"
      ;;
    relative)
      cd "$case_root"
      entrypoint="./repo with spaces/setup.sh"
      ;;
    absolute)
      cd "$HOME"
      entrypoint="$repo/setup.sh"
      ;;
  esac

  if ! bash "$entrypoint" "$@" </dev/null > "$case_root/setup.log" 2>&1; then
    if [ "$PKG_UPGRADE_FAIL" = "1" ]; then
      command grep -q "Failed to upgrade Termux packages" "$case_root/setup.log"
      test ! -e "$HOME/.packages-upgraded"
      test ! -d "$HOME/.gyp"
      test ! -d "$install_root/node_modules"
      exit 0
    fi
    if [ "$LIBSECRET_INSTALL_FAIL" = "1" ]; then
      command grep -q "Failed to install libsecret" "$case_root/setup.log"
      test ! -d "$install_root/node_modules/keytar"
      exit 0
    fi
    cat "$case_root/setup.log" >&2
    exit 1
  fi
  if [ "$LIBSECRET_INSTALL_FAIL" = "1" ] || [ "$PKG_UPGRADE_FAIL" = "1" ]; then
    echo "Setup should have stopped when a package operation failed" >&2
    exit 1
  fi
  if [ "$mode" = "install" ]; then
    test -f "$HOME/.packages-upgraded"
    test "$(command grep -cx 'upgrade -y' "$HOME/pkg.log")" = 1
  else
    test ! -e "$HOME/.packages-upgraded"
  fi

  for file in "$repo"/shim/*; do
    cmp "$file" "$HOME/.copilot-versions/shim/$(basename "$file")"
  done

  cmp "$repo/scripts/copilot-wrapper.sh" "$HOME/.local/bin/copilot"
  cmp "$repo/scripts/pty_tui_test.py" "$HOME/.copilot-versions/pty_tui_test.py"
  test -x "$HOME/.local/bin/copilot"
  test -x "$HOME/.copilot-versions/pty_tui_test.py"
  if [ "$mode" = "update-backup" ]; then
    command grep -qx "existing pty" "$install_root/prebuilds/android-arm64/pty.node"
  else
    command grep -qx "rebuilt pty" "$install_root/prebuilds/android-arm64/pty.node"
  fi
)

for mode in install update-rebuild update-backup; do
  for invocation in local relative absolute; do
    run_case "$mode" "$invocation"
    echo "PASS: $mode ($invocation path)"
  done
done

run_case install local 1
echo "PASS: libsecret installation failure stops setup before keytar"

run_case install local 0 1
echo "PASS: package upgrade failure stops setup before installing dependencies"
