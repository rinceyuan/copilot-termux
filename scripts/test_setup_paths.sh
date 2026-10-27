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
node() {
  if [ "${1:-}" = "-p" ]; then
    if [ "$PACKAGE_SCENARIO" = "version-failure" ]; then
      echo "Mock damaged package.json" >&2
      return 1
    fi
    echo "1.0.97"
  fi
  return 0
}
python3() {
  if [[ "$1" == */scripts/check_termux_python.py ]]; then
    test -f "$1" || return 1
    if [ "$PYTHON_CHECK_FAIL" = "1" ]; then
      echo "Mock Python/package health check failed" >&2
      return 1
    fi
    : > "$HOME/.python-checked"
  fi
  return 0
}
patchelf() { return 0; }
llvm-objcopy() { return 0; }

npm() {
  case "${1:-}" in
    install|update) : > "$HOME/.npm-install-attempted" ;;
  esac
  if [ "$*" = "install -g @github/copilot" ] && [ ! -f "$HOME/.python-checked" ]; then
    echo "Python must be checked before installing Copilot" >&2
    return 1
  fi
  case "$*" in
    "install -g @github/copilot@1.0.97 --force")
      if [ "$PACKAGE_SCENARIO" = "stub-failure" ]; then
        echo "npm error mock failed stub download" >&2
        return 1
      fi
      echo "Mock npm: $*"
      ;;
    "install -g --force @github/copilot-linuxmusl-arm64@1.0.97")
      if [ "$PACKAGE_SCENARIO" = "platform-failure" ]; then
        echo "npm error mock failed platform download" >&2
        return 1
      fi
      : > "$HOME/.platform-installed"
      echo "Mock npm: $*"
      ;;
    "root -g") echo "$HOME/npm/lib/node_modules" ;;
    "list -g @github/copilot") echo "@github/copilot@$INSTALLED_VERSION" ;;
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
  export PYTHON_CHECK_FAIL="${5:-0}"
  export PACKAGE_SCENARIO="${6:-legacy}"
  export INSTALLED_VERSION=1.0.91
  [ "$mode" != "update-current" ] || export INSTALLED_VERSION=1.0.97
  case_root="$TEST_ROOT/$mode-$invocation-$LIBSECRET_INSTALL_FAIL-$PKG_UPGRADE_FAIL-$PYTHON_CHECK_FAIL-$PACKAGE_SCENARIO"
  repo="$case_root/repo with spaces"
  export HOME="$case_root/home with spaces"
  export PREFIX="$HOME/usr" TERMUX_VERSION="test"
  unset CDPATH COPILOT_MAX_VERSION COPILOT_ALLOW_BROKEN
  install_root="$HOME/npm/lib/node_modules/@github/copilot"
  mkdir -p "$repo/shim" "$repo/scripts" "$install_root/prebuilds/android-arm64"
  cp "$REPO_ROOT/setup.sh" "$repo/setup.sh"
  cp "$REPO_ROOT/scripts/check_termux_python.py" "$repo/scripts/"
  if [ "$PACKAGE_SCENARIO" != "legacy" ]; then
    : > "$install_root/npm-loader.js"
  fi

  for file in bionic_shim.c strip_verneed.py patch_js.py gai_xlate.c \
              pthread_xlate.c rename_imports.py patch_mouse.py extract_sea.py \
              spawn_xlate.c tls_xlate.c; do
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
  elif [ "$mode" = "update-current" ]; then
    mkdir -p "$HOME/.local/bin" "$HOME/.copilot-versions/shim"
    echo stale > "$HOME/.local/bin/copilot"
    echo stale > "$HOME/.copilot-versions/shim/spawn_xlate.c"
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
    case "$PACKAGE_SCENARIO" in
      platform-failure)
        command grep -q "Could not install @github/copilot-linuxmusl-arm64@1.0.97" "$case_root/setup.log"
        test ! -d "$install_root/node_modules"
        exit 0
        ;;
      stub-failure)
        command grep -q "npm update failed" "$case_root/setup.log"
        test ! -d "$install_root/node_modules"
        exit 0
        ;;
      version-failure)
        command grep -q "Could not read a valid Copilot package version" "$case_root/setup.log"
        test ! -e "$HOME/.platform-installed"
        exit 0
        ;;
    esac
    if [ "$PYTHON_CHECK_FAIL" = "1" ]; then
      command grep -q "Python verification failed" "$case_root/setup.log"
      test ! -e "$HOME/.python-checked"
      test ! -d "$HOME/.gyp"
      test ! -d "$install_root/node_modules"
      exit 0
    fi
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
  case "$PACKAGE_SCENARIO" in
    *-failure) echo "Setup ignored a failed package operation" >&2; exit 1 ;;
    split)
      test -f "$HOME/.platform-installed" || {
        echo "Setup skipped the missing platform package because prebuilds already existed" >&2
        exit 1
      }
      ;;
  esac
  if [ "$LIBSECRET_INSTALL_FAIL" = "1" ] || [ "$PKG_UPGRADE_FAIL" = "1" ] || \
     [ "$PYTHON_CHECK_FAIL" = "1" ]; then
    echo "Setup should have stopped when a package operation failed" >&2
    exit 1
  fi
  if [ "$mode" = "install" ]; then
    test -f "$HOME/.python-checked"
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
  if [ "$mode" = "update-current" ]; then
    test ! -e "$HOME/.npm-install-attempted"
    test ! -e "$install_root/prebuilds/android-arm64/pty.node"
    command grep -q "Already up to date" "$case_root/setup.log"
  elif [ "$mode" = "update-backup" ]; then
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

run_case update-current local
echo "PASS: same-version update refreshes compatibility sources and launcher without npm install"

run_case install local 1
echo "PASS: libsecret installation failure stops setup before keytar"

run_case install local 0 1
echo "PASS: package upgrade failure stops setup before installing dependencies"

run_case install local 0 0 1
echo "PASS: Python health check failure stops setup before node-gyp or Copilot"

for mode in install update-rebuild; do
  run_case "$mode" local 0 0 0 split
  echo "PASS: $mode restores the platform package despite leftover prebuilds"
  run_case "$mode" local 0 0 0 platform-failure
  echo "PASS: $mode does not mask npm platform failures with grep"
done
run_case update-rebuild local 0 0 0 stub-failure
echo "PASS: update does not mask npm stub failure with grep"
run_case install local 0 0 0 version-failure
echo "PASS: invalid stub metadata cannot trigger an unpinned platform installation"
