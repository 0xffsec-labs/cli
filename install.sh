#!/bin/sh

set -eu

APP_NAME="RemoteCodex"
COMMAND_NAME="${REMOTECODEX_COMMAND:-remote-codex}"
RELEASE_REPO="${REMOTECODEX_GITHUB_REPO:-0xffsec-labs/cli}"
RELEASE="${REMOTECODEX_RELEASE:-latest}"
NON_INTERACTIVE="${REMOTECODEX_NON_INTERACTIVE:-false}"

BIN_DIR="${REMOTECODEX_INSTALL_DIR:-$HOME/.local/bin}"
BIN_PATH="$BIN_DIR/$COMMAND_NAME"
INSTALL_HOME="${REMOTECODEX_HOME:-$HOME/.remotecodex}"
STANDALONE_ROOT="$INSTALL_HOME/packages/standalone"
RELEASES_DIR="$STANDALONE_ROOT/releases"
CURRENT_LINK="$STANDALONE_ROOT/current"
LOCK_DIR="$STANDALONE_ROOT/install.lock.d"
LOCK_STALE_AFTER_SECS=600

path_action="already"
path_profile=""
tmp_dir=""

step() {
  printf '==> %s\n' "$1"
}

warn() {
  printf 'WARNING: %s\n' "$1" >&2
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "$1 is required to install $APP_NAME." >&2
    exit 1
  fi
}

download_file() {
  url="$1"
  output="$2"

  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$output"
    return
  fi

  if command -v wget >/dev/null 2>&1; then
    wget -q -O "$output" "$url"
    return
  fi

  echo "curl or wget is required to install $APP_NAME." >&2
  exit 1
}

download_text() {
  url="$1"

  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url"
    return
  fi

  if command -v wget >/dev/null 2>&1; then
    wget -q -O - "$url"
    return
  fi

  echo "curl or wget is required to install $APP_NAME." >&2
  exit 1
}

file_sha256() {
  path="$1"

  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$path" | awk '{print $1}'
    return
  fi

  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$path" | awk '{print $1}'
    return
  fi

  if command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 "$path" | sed 's/^.*= //'
    return
  fi

  echo "sha256sum, shasum, or openssl is required to verify the download." >&2
  exit 1
}

verify_archive_digest() {
  archive_path="$1"
  expected_digest="$2"
  actual_digest="$(file_sha256 "$archive_path")"

  if [ "$actual_digest" != "$expected_digest" ]; then
    echo "Downloaded $APP_NAME archive checksum did not match expected digest." >&2
    echo "expected: $expected_digest" >&2
    echo "actual:   $actual_digest" >&2
    exit 1
  fi
}

package_archive_digest() {
  asset="$1"
  manifest_path="$2"

  digest="$(awk -v asset="$asset" '
    $2 == asset && length($1) == 64 && $1 !~ /[^0-9a-fA-F]/ {
      print tolower($1)
      found = 1
      exit
    }
    END {
      if (!found) {
        exit 1
      }
    }
  ' "$manifest_path" 2>/dev/null || true)"

  if [ -z "$digest" ]; then
    echo "Could not find SHA-256 digest for $asset in codex-package_SHA256SUMS." >&2
    exit 1
  fi

  printf '%s\n' "$digest"
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --release)
        if [ "$#" -lt 2 ]; then
          echo "--release requires a value." >&2
          exit 1
        fi
        RELEASE="$2"
        shift
        ;;
      --help | -h)
        cat <<EOF
Usage: install.sh [--release VERSION_OR_TAG]

Environment:
  REMOTECODEX_RELEASE          GitHub release tag, version, or latest.
  REMOTECODEX_GITHUB_REPO      GitHub owner/repo. Default: 0xffsec-labs/cli.
  REMOTECODEX_COMMAND          Visible command. Default: remote-codex.
  REMOTECODEX_INSTALL_DIR      Directory for the command symlink.
  REMOTECODEX_HOME             Package install root.
  REMOTECODEX_NON_INTERACTIVE  Set to 1, true, or yes to skip prompts.
EOF
        exit 0
        ;;
      *)
        echo "Unknown argument: $1" >&2
        exit 1
        ;;
    esac
    shift
  done
}

github_api_url_for_release() {
  release="$1"

  if [ "$release" = "latest" ]; then
    printf 'https://api.github.com/repos/%s/releases/latest\n' "$RELEASE_REPO"
    return
  fi

  case "$release" in
    rust-v* | v*)
      tag="$release"
      ;;
    *)
      tag="rust-v$release"
      ;;
  esac
  printf 'https://api.github.com/repos/%s/releases/tags/%s\n' "$RELEASE_REPO" "$tag"
}

json_string_field() {
  field="$1"
  sed -n "s/.*\"$field\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" | head -n 1
}

asset_download_url() {
  release_json_path="$1"
  asset="$2"

  awk -v asset="$asset" '
    /"name":[[:space:]]*"[^"]+"/ {
      name = $0
      sub(/^.*"name":[[:space:]]*"/, "", name)
      sub(/".*$/, "", name)
      in_asset = (name == asset)
    }

    in_asset && /"browser_download_url":[[:space:]]*"[^"]+"/ {
      url = $0
      sub(/^.*"browser_download_url":[[:space:]]*"/, "", url)
      sub(/".*$/, "", url)
      print url
      exit
    }
  ' "$release_json_path"
}

resolve_release() {
  release_json="$tmp_dir/release.json"
  download_text "$(github_api_url_for_release "$RELEASE")" >"$release_json"
  release_tag="$(json_string_field tag_name <"$release_json")"

  if [ -z "$release_tag" ]; then
    echo "Failed to resolve $APP_NAME release '$RELEASE' from $RELEASE_REPO." >&2
    exit 1
  fi

  printf '%s\n' "$release_tag"
}

pick_profile() {
  case "$os:${SHELL:-}" in
    darwin:*/zsh)
      printf '%s\n' "$HOME/.zprofile"
      ;;
    darwin:*/bash)
      printf '%s\n' "$HOME/.bash_profile"
      ;;
    linux:*/zsh)
      printf '%s\n' "$HOME/.zshrc"
      ;;
    linux:*/bash)
      printf '%s\n' "$HOME/.bashrc"
      ;;
    *)
      printf '%s\n' "$HOME/.profile"
      ;;
  esac
}

add_to_path() {
  path_action="already"
  path_profile=""

  case ":$PATH:" in
    *":$BIN_DIR:"*)
      return
      ;;
  esac

  profile="$(pick_profile)"
  path_profile="$profile"
  begin_marker="# >>> RemoteCodex installer >>>"
  end_marker="# <<< RemoteCodex installer <<<"
  path_line="export PATH=\"$BIN_DIR:\$PATH\""

  if [ -f "$profile" ] && grep -F "$begin_marker" "$profile" >/dev/null 2>&1; then
    path_action="configured"
    return
  fi

  {
    printf '\n%s\n' "$begin_marker"
    printf '%s\n' "$path_line"
    printf '%s\n' "$end_marker"
  } >>"$profile"
  path_action="added"
}

mkdir_lock_is_stale() {
  [ -d "$LOCK_DIR" ] || return 1

  pid="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
  started_at="$(cat "$LOCK_DIR/started_at" 2>/dev/null || true)"
  now="$(date +%s 2>/dev/null || printf '0')"

  case "$started_at" in
    ''|*[!0-9]*)
      started_at=0
      ;;
  esac

  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    return 1
  fi

  if [ "$started_at" -eq 0 ] || [ "$now" -eq 0 ]; then
    return 0
  fi

  [ $((now - started_at)) -ge "$LOCK_STALE_AFTER_SECS" ]
}

acquire_install_lock() {
  mkdir -p "$STANDALONE_ROOT"

  while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    if mkdir_lock_is_stale; then
      warn "Removing stale installer lock at $LOCK_DIR"
      rm -rf "$LOCK_DIR"
      continue
    fi
    sleep 1
  done

  printf '%s\n' "$$" >"$LOCK_DIR/pid"
  date +%s >"$LOCK_DIR/started_at" 2>/dev/null || true
}

release_install_lock() {
  rm -rf "$LOCK_DIR" 2>/dev/null || true
}

replace_path_with_symlink() {
  link_path="$1"
  link_target="$2"
  tmp_link="$3"

  rm -f "$tmp_link"
  ln -s "$link_target" "$tmp_link"

  if mv -Tf "$tmp_link" "$link_path" 2>/dev/null; then
    return
  fi

  if mv -hf "$tmp_link" "$link_path" 2>/dev/null; then
    return
  fi

  rm -f "$link_path"
  mv -f "$tmp_link" "$link_path"
}

install_package_release() {
  release_dir="$1"
  archive_path="$2"
  stage_release="$RELEASES_DIR/.staging.$(basename "$release_dir").$$"

  mkdir -p "$RELEASES_DIR"
  rm -rf "$stage_release"
  mkdir -p "$stage_release"
  tar -xzf "$archive_path" -C "$stage_release"
  chmod 0755 "$stage_release/bin/codex" "$stage_release/codex-path/rg"
  if [ -f "$stage_release/codex-resources/bwrap" ]; then
    chmod 0755 "$stage_release/codex-resources/bwrap"
  fi
  ln -sf "bin/codex" "$stage_release/codex"

  if [ -e "$release_dir" ] || [ -L "$release_dir" ]; then
    rm -rf "$release_dir"
  fi
  mv "$stage_release" "$release_dir"
}

release_dir_is_complete() {
  release_dir="$1"
  expected_target="$2"

  [ -d "$release_dir" ] || return 1
  [ -f "$release_dir/codex-package.json" ] || return 1
  [ -x "$release_dir/bin/codex" ] || return 1
  [ -x "$release_dir/codex" ] || return 1
  [ -x "$release_dir/codex-path/rg" ] || return 1

  case "$expected_target" in
    *linux*) [ -x "$release_dir/codex-resources/bwrap" ] ;;
    *) true ;;
  esac
}

version_from_binary() {
  codex_path="$1"

  if [ ! -x "$codex_path" ]; then
    return 1
  fi

  "$codex_path" --version 2>/dev/null | sed -n 's/.* \([0-9][0-9A-Za-z.+-]*\)$/\1/p' | head -n 1
}

current_installed_version() {
  version="$(version_from_binary "$CURRENT_LINK/bin/codex" || true)"
  if [ -n "$version" ]; then
    printf '%s\n' "$version"
  fi
}

print_launch_instructions() {
  case "$path_action" in
    added)
      step "Current terminal: export PATH=\"$BIN_DIR:\$PATH\" && $COMMAND_NAME"
      step "Future terminals: open a new terminal and run: $COMMAND_NAME"
      step "PATH was added to $path_profile"
      ;;
    configured)
      step "Current terminal: export PATH=\"$BIN_DIR:\$PATH\" && $COMMAND_NAME"
      step "Future terminals: open a new terminal and run: $COMMAND_NAME"
      step "PATH is already configured in $path_profile"
      ;;
    *)
      step "$BIN_DIR is already on PATH"
      step "Run: $COMMAND_NAME"
      ;;
  esac
}

maybe_launch_now() {
  case "$NON_INTERACTIVE" in
    1 | [Tt][Rr][Uu][Ee] | [Yy][Ee][Ss])
      return
      ;;
  esac

  if [ ! -t 0 ]; then
    return
  fi

  if ( : </dev/tty ) 2>/dev/null; then
    printf 'Start %s now? [y/N] ' "$APP_NAME" >/dev/tty
    if IFS= read -r answer </dev/tty; then
      case "$answer" in
        y | Y | yes | YES)
          step "Launching $APP_NAME"
          "$BIN_PATH"
          ;;
      esac
    fi
  fi
}

parse_args "$@"

require_command mktemp
require_command tar

case "$(uname -s)" in
  Darwin)
    os="darwin"
    ;;
  *)
    echo "install.sh currently supports macOS only." >&2
    exit 1
    ;;
esac

case "$(uname -m)" in
  x86_64 | amd64)
    arch="x86_64"
    ;;
  arm64 | aarch64)
    arch="aarch64"
    ;;
  *)
    echo "Unsupported architecture: $(uname -m)" >&2
    exit 1
    ;;
esac

if [ "$os" = "darwin" ] && [ "$arch" = "x86_64" ]; then
  if [ "$(sysctl -n sysctl.proc_translated 2>/dev/null || true)" = "1" ]; then
    arch="aarch64"
  fi
fi

if [ "$arch" = "aarch64" ]; then
  vendor_target="aarch64-apple-darwin"
  platform_label="macOS (Apple Silicon)"
else
  echo "RemoteCodex build is not ready for macOS (Intel) yet." >&2
  exit 1
fi

tmp_dir="$(mktemp -d)"
cleanup() {
  release_install_lock
  if [ -n "$tmp_dir" ]; then
    rm -rf "$tmp_dir"
  fi
}
trap cleanup EXIT INT TERM

release_tag="$(resolve_release)"
release_json="$tmp_dir/release.json"
asset="codex-package-$vendor_target.tar.gz"
checksum_asset="codex-package_SHA256SUMS"
download_url="$(asset_download_url "$release_json" "$asset")"
checksum_url="$(asset_download_url "$release_json" "$checksum_asset")"

if [ -z "$download_url" ] || [ -z "$checksum_url" ]; then
  echo "Could not find $asset and $checksum_asset on $RELEASE_REPO release $release_tag." >&2
  exit 1
fi

release_name="$release_tag-$vendor_target"
release_dir="$RELEASES_DIR/$release_name"
current_version="$(current_installed_version)"

if [ -n "$current_version" ]; then
  step "Updating $APP_NAME from installed Codex binary $current_version"
else
  step "Installing $APP_NAME"
fi
step "Detected platform: $platform_label"
step "Resolved release: $release_tag"

acquire_install_lock

if ! release_dir_is_complete "$release_dir" "$vendor_target"; then
  archive_path="$tmp_dir/$asset"
  checksum_path="$tmp_dir/$checksum_asset"

  step "Downloading $APP_NAME package"
  download_file "$checksum_url" "$checksum_path"
  expected_digest="$(package_archive_digest "$asset" "$checksum_path")"
  download_file "$download_url" "$archive_path"
  verify_archive_digest "$archive_path" "$expected_digest"

  step "Installing standalone package to $release_dir"
  install_package_release "$release_dir" "$archive_path"
fi

replace_path_with_symlink "$CURRENT_LINK" "$release_dir" "$STANDALONE_ROOT/.current.$$"
mkdir -p "$BIN_DIR"
replace_path_with_symlink "$BIN_PATH" "$CURRENT_LINK/bin/codex" "$BIN_DIR/.$COMMAND_NAME.$$"
"$BIN_PATH" --version >/dev/null
add_to_path
release_install_lock

print_launch_instructions
printf '%s %s installed successfully as %s.\n' "$APP_NAME" "$release_tag" "$COMMAND_NAME"
maybe_launch_now
