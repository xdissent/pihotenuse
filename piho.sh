#!/usr/bin/env bash #                 To install: bash <(curl https://piho.sh)
[ -z "${0##/dev/fd*}" ] && cp "$0" "$TMPDIR/piho" && bash "$_" install || true
#!/usr/bin/env bash #                                        pihotenuse v0.0.3
#                                                          https://pihotenu.se

set -e
[ -z "$PIHO_TRACE" ] || set -x

case "$(uname -s)" in
  "Darwin") export PIHO_HOME="${PIHO_HOME:-"$HOME/.pihotenuse"}" ;;
  "Linux")  export PIHO_HOME="${PIHO_HOME:-"/piho/home"}" ;;
esac

RASPBIAN_LATEST="http://downloads.raspberrypi.org/raspbian_latest"
PIHO_IMAGE="${PIHO_IMAGE:-"$PIHO_HOME/base.img"}"
PIHO_IMAGE_URL="${PIHO_IMAGE_URL:-"$RASPBIAN_LATEST"}"

PIHO_DOCKER_BASE_IMAGE="${PIHO_DOCKER_BASE_IMAGE:-"ubuntu:latest"}"
PIHO_DOCKER_IMAGE="${PIHO_DOCKER_IMAGE:-"xdissent/pihotenuse"}"

PIHO_DEBS="${PIHO_DEBS:-"$PIHO_HOME/debs"}"
PIHO_DEBS_KEY_PRIVATE="${PIHO_DEBS_KEY_PRIVATE:-"$PIHO_HOME/debs-private.key"}"
PIHO_DEBS_KEY_PUBLIC="${PIHO_DEBS_KEY_PUBLIC:-"$PIHO_DEBS/public.key"}"

# TODO: cross platform inexpensive random regex-safe string generator
PIHO_SENTINEL="hiphopanonamus"
PIHO_VERSION="$(head -4 "$0" | egrep -o 'v\d+.\d+.\d+' || echo "unknown")"

PIHO_UPGRADE_URL="${PIHO_UPGRADE_URL:-"https://piho.sh"}"
PIHO_DEFAULT_INSTALL_PATH="/usr/local/bin"

#
# Logging/debugging/error handling helpers
#

RED="\033[0;31m"
REDB="\033[1;31m"
GREEN="\033[0;32m"
GREENB="\033[1;32m"
YELLOW="\033[0;33m"
YELLOWB="\033[1;33m"
BLUE="\033[0;34m"
BLUEB="\033[1;34m"
MAGENTA="\033[0;35m"
MAGENTAB="\033[1;35m"
CYAN="\033[0;36m"
CYANB="\033[1;36m"
GRAY="\033[0;37m"
GRAYB="\033[1;37m"
BOLD="\033[1m"
RESET="\033[0m"

fail() {
  echo -e "${REDB}ERROR:${RESET} $1"
  [ -n "$2" ] || exit 1
  exit "$2"
}

warn() { echo -e "${YELLOWB}WARNING:${RESET} $1"; }

debug() {
  [ -n "$PIHO_DEBUG" ] || return 0
  local COLOR="$GRAY"
  [ -z "$PIHO_TRACE" ] || COLOR="$CYAN"
  echo -e "${COLOR}$1${RESET}"
}

info() {
  local COLOR="$BOLD"
  [ -z "$PIHO_TRACE" ] || COLOR="$MAGENTA"
  echo -e "${COLOR}$1${RESET}";
}

#
# Boot2docker helpers
#

# Initializes boot2docker config and ensures the vm is running
b2d_init() {
  debug "Checking for boot2docker"
  which boot2docker &> /dev/null || fail "Could not find boot2docker in path"

  debug "Exporting b2d env vars"
  export BOOT2DOCKER_DIR="$PIHO_HOME"
  export BOOT2DOCKER_PROFILE="$PIHO_HOME/b2d.profile"
  
  debug "Creating boot2docker profile"
  [ -f "$BOOT2DOCKER_PROFILE" ] || cat > "$BOOT2DOCKER_PROFILE" <<EOF
SSHPort = 2023
SSHKey = "$HOME/.ssh/id_pihotenuse"
VM = "pihotenuse-vm"
EOF

  debug "Checking boot2docker status"
  case "$(boot2docker status 2> /dev/null || true)" in
    "")
      info "Initializing boot2docker"
      boot2docker init &> /dev/null || fail "Could not initialize boot2docker"
      b2d_start
      ;;
    "poweroff") b2d_start ;;
    "running") ;;
    *) fail "Unknown boot2docker status" ;;
  esac
}

# Starts boot2docker and loads nbd kernel module in b2d vm
b2d_start() {
  info "Starting boot2docker"
  boot2docker start &> /dev/null ||
    fail "Could not start boot2docker" $?

  local N=0
  while [ "$(boot2docker status 2> /dev/null || true)" != "running" ]; do
    sleep 1
    debug "Waiting for boot2docker status change"
    N=$[$N+1]
    [ $N -le 5 ] || fail "Starting boot2docker took too long"
  done

  debug "Loading nbd kernel module in boot2docker vm"
  boot2docker ssh sudo modprobe nbd
}

#
# Docker helpers
#

# Sets up the b2d shell environment and creates the docker image if not found
docker_init() {
  debug "Setting docker shell environment"
  $(SHELL=/bin/bash boot2docker shellinit 2> /dev/null)

  debug "Checking for pihotenuse docker image"
  docker images 2> /dev/null | egrep -q "^$PIHO_DOCKER_IMAGE " &&
    return 0 || true

  # HACK: This should be a Dockerfile but they currently can't run privileged
  # operations when being built: https://github.com/docker/docker/issues/1916
  debug "Initializing pihotenuse docker image"
  docker run --privileged "$PIHO_DOCKER_BASE_IMAGE" \
    bash -c "apt-get update &&
      apt-get install -y qemu-user-static qemu-utils &&
      mkdir -p /piho/bin"

  docker_commit
  piho_update "no"
}

# Commits the last-run container into the pihotenuse image
docker_commit() {
  debug "Committing pihotenuse docker image"
  local CID="$(docker ps -l -q)"
  docker commit "$CID" "$PIHO_DOCKER_IMAGE" &> /dev/null
  docker rm "$CID" &> /dev/null
}

# Resets workdir, env and cmd for the pihotenuse docker image
docker_reset() {
  debug "Resetting pihotenuse docker image"
  CID="$(docker create --privileged -w /piho -e PIHO_HOME=/piho/home \
-e PATH=/piho/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
"$PIHO_DOCKER_IMAGE" bash)"
  docker commit "$CID" "$PIHO_DOCKER_IMAGE" &> /dev/null
  docker rm "$CID" &> /dev/null
}

# Run a command inside a container
docker_run() {
  docker run --privileged --rm -v "$PIHO_HOME:/piho/home" \
    -e "PIHO_TRACE=$PIHO_TRACE" -e "PIHO_DEBUG=$PIHO_DEBUG" \
    "$PIHO_DOCKER_IMAGE" bash -c 'exec "$@"' piho "$@"
}

# Execute a piho command inside a container replacing this process
docker_exec() {
  exec docker run -i --privileged --rm -v "$PIHO_HOME:/piho/home" \
    -e "PIHO_TRACE=$PIHO_TRACE" -e "PIHO_DEBUG=$PIHO_DEBUG" \
    "$PIHO_DOCKER_IMAGE" bash -c 'exec "$@"' piho "$@"
}

# Execute a piho command inside a container with a tty replacing this process
docker_exec_tty() {
  exec docker run -it --privileged --rm -v "$PIHO_HOME:/piho/home" \
    -e "PIHO_TRACE=$PIHO_TRACE" -e "PIHO_DEBUG=$PIHO_DEBUG" \
    "$PIHO_DOCKER_IMAGE" bash -c 'exec "$@"' piho "$@"
}

#
# Piho helpers
#

# Downloads a base disk image if not found
piho_image_init() {
  debug "Checking for pihotenuse disk image"
  [ -f "$PIHO_IMAGE" ] && return 0

  [ -z "$1" ] || {
    info "Copying base disk image"
    cp "$1" "$PIHO_IMAGE"
    return 0
  }

  info "Downloading base disk image"
  mkdir -p /tmp/piho
  curl -L -o "/tmp/piho/img.zip" "$PIHO_IMAGE_URL" ||
    fail "Failed to download image"
  unzip -j -d /tmp/piho /tmp/piho/img.zip
  mv /tmp/piho/*.img "$PIHO_IMAGE"
  rm -rf /tmp/piho
}

# Displays a pretty triangle
piho_banner() {
  local TITLE="${YELLOW}pihotenuse${RESET} ${GRAY}$PIHO_VERSION${RESET}"
  local TAGLINE="raspberry ${MAGENTA}pi${RESET} image development tool"
  echo -e "
    |${BOLD}\ ${RESET}
    | ${BOLD}\ ${RESET}   $TITLE
    |${GRAY}_${RESET} ${BOLD}\ ${RESET}   $TAGLINE
    |_${GRAY}|${RESET}_${BOLD}\ ${RESET}"
}

# Checks if a piho image exists by name
piho_exists() {
  debug "Checking for image $1"
  [ -f "$PIHO_HOME/images/$1.qcow2" ]
}

# Creates the debs image with a gpg key, more free space, and dev tools
piho_create_debs() {
  piho_init
  piho_exists debs && return 0

  piho_create debs

  debug "Checking gpg key"
  [ -f "$PIHO_DEBS_KEY_PRIVATE" ] || docker_run piho container-debs-key

  debug "Removing packages and adding dev tools"
  docker_run piho container-run debs bash -c "
    apt-get remove -y --purge \
      scratch \
      pypy-upstream \
      sonic-pi \
      freepats \
      libraspberrypi-doc \
      oracle-java8-jdk \
      wolfram-engine &&
    apt-get autoremove -y &&
    apt-get install -y debhelper python-stdeb"
}

# Tries to (silently) run a command and then does it again with sudo if it fails
piho_try_sudo() {
  "$@" &> /dev/null && return 0 || true
  debug "Command failed, trying with sudo: $@"
  sudo "$@" &> /dev/null
}

# Copies the piho script source somewhere an sets it executable
piho_install_copy() {
  local SOURCE="$1"
  local DEST="$2"

  piho_try_sudo mkdir -p "$(dirname "$DEST")" ||
    fail "Could not create installation dir"

  piho_try_sudo cp "$SOURCE" "$DEST" ||
    fail "Could not copy piho into installation dir"

  piho_try_sudo chmod 755 "$DEST" ||
    fail "Failed to set piho permissions"
}

# Determines whether a given device is an SD card
piho_sd_device_check() {
  local PATTERN="Ejectable:.*Yes|IOContent.*FDisk"
  local REQUIRED="2"
  local MATCHES="$(diskutil info "$1" | grep -E "$PATTERN" | wc -l |
    awk '{print$1}' || true)"
  [ "$MATCHES" = "$REQUIRED" ]
}

# Outputs the name of the first disk device that looks like an SD card
piho_sd_device() {
  local DEV=""
  for DEV in $(diskutil list | sed -n '/^\//p' | uniq); do
    piho_sd_device_check "$DEV" || continue
    echo "$DEV"
    return 0
  done
  return 1
}

# Bails if an image by the given name does not exist
piho_check_image() {
  [ -n "$1" ] || fail "Image name required"
  piho_exists "$1" || fail "Image $1 does not exist"
}

#
# Piho commands
#

# Initializes piho, b2d, docker and downloads a base image
# TODO: not so aggressive
piho_init() {
  mkdir -p "$PIHO_HOME"
  b2d_init
  docker_init
  debs_init
  piho_image_init "$1"
}

# Installs piho onto the host system
piho_install() {
  piho_banner && echo

  info "Installing pihotenuse $PIHO_VERSION"
  local DEST=""
  local PROMPT="[${GRAY}$PIHO_DEFAULT_INSTALL_PATH${RESET}]: "

  echo -en "\nWhere would you like to install pihotenuse? $PROMPT"
  read DEST

  [ -n "$DEST" ] || DEST="$PIHO_DEFAULT_INSTALL_PATH"

  [[ ":$PATH:" == *":$DEST:"* ]] ||
    warn "The installation directory '$DEST' is not on your PATH"
  
  debug "Copying piho to $DEST/piho"
  piho_install_copy "$0" "$DEST/piho"

  info "Pihotenuse installed successfully. Run 'piho init' to get started!"
  [ "$0" != "${0##$TMPDIR}" ] || return 0
  debug "Removing temporary install $0"
  rm -f "$0"
}

# Lists available piho images
piho_list() {
  find "$PIHO_HOME/images/" -name "*.qcow2" \
    -exec basename {} .qcow2 \; 2> /dev/null || true
}

# Upgrades piho to the latest available version
piho_upgrade() {
  info "Upgrading pihotenuse"
  debug "Downloading piho"
  curl -sL -o "$TMPDIR/piho" "$PIHO_UPGRADE_URL" ||
    fail "Failed to download latest piho version"
  piho_install_copy "$TMPDIR/piho" "$0" && exec bash "$0" update
}

# Updates the piho script inside the container
piho_update() {
  # HACK: docker_init doesn't need piho_init
  [ "$1" = "no" ] || {
    piho_init
    info "Updating pihotenuse"
  }

  debug "Copying piho into container"
  # For some reason the container's bash chokes on comments after the shebang
  sed '1s/bash.*/bash/' "$0" | docker run -i --privileged \
    -v "$PIHO_HOME:/piho/home" "$PIHO_DOCKER_IMAGE" bash -c \
    "tee /piho/bin/piho && chmod +x /piho/bin/piho" &> /dev/null ||
      fail "Failed to update"
  docker_commit
  docker_reset
}

# Creates a piho image with the given name
piho_create() {
  piho_exists "$1" && fail "$1 already exists" || true
  piho_init

  debug "Creating images folder if required"
  mkdir -p "$PIHO_HOME/images"

  info "Creating image $1"
  docker_run qemu-img create -f qcow2 -b home/base.img \
    "home/images/$1.qcow2" &> /dev/null || fail "Failed to create image $1"
}

# Deletes a piho image
piho_remove() {
  piho_check_image "$1"
  info "Removing image $1"
  rm -f "$PIHO_HOME/images/$1.qcow2"
}

# Clones a piho image
piho_clone() {
  piho_check_image "$1"
  piho_exists "$2" && fail "$2 already exists" || true
  info "Cloning image $1 as $2"
  cp "$PIHO_HOME/images/$1.qcow2" "$PIHO_HOME/images/$2.qcow2"
}

# Launches an interactive shell for the given image
piho_shell() {
  piho_check_image "$1"
  piho_init
  info "Launching shell for $1"
  docker_exec_tty piho container-shell "$@"
}

# Runs a command inside an image
piho_run() {
  piho_check_image "$1"
  piho_init
  debug "Running command for $1" # Only debug so stdout isn't jacked
  docker_exec piho container-run "$@"
}

# Builds/installs a deb into the local apt repo
piho_deb() {
  piho_create_debs

  # For .deb files, just copy them immediately and re-index
  local FILE="$(basename "${2%%\?*}")"
  local EXT="${FILE##*.}"
  [ "$EXT" != "deb" ] || {
    mkdir -p "$PIHO_DEBS/$1"
    pushd "$PIHO_DEBS/$1"
    curl -LO "$2"
    popd
    piho_index
    return 0
  }

  debug "Building deb"
  docker_exec piho container-deb "$@"
}

# Builds a deb from an sdist python tarball
piho_pydeb() {
  piho_deb "$1" "$2" "$3" "$4" "debs_pyget"
}

# Lists the installed debs
piho_debs() {
  grep "Package:" "$PIHO_DEBS/Packages" | sed 's/Package: //' ||
    info "No debs found"
}

# Recreates the apt repo index, picking up any new debs
piho_index() {
  piho_create_debs

  debug "Indexing debs"
  docker_exec piho container-debs-index "$@"
}

# Applies the cow image changes to the base image and writes out a raw img file
piho_export() {
  piho_check_image "$1"
  piho_init

  info "Exporting image for $1"
  docker_run piho container-export "$1" || fail "Failed to export image"

  [ "$2" != "$PIHO_HOME/images/$1.img" ] || return 0

  debug "Moving exported image"
  mv "$PIHO_HOME/images/$1.img" "$2" ||
    fail "Failed to move exported image"
}

# Exports an image and writes it directly to a block device
piho_flash() {
  # TODO: this should be run as root but b2d gets all funky. Gotta fix ENV
  # [ "$(whoami)" = "root" ] || fail "Flash command must be run as root (sudo)"

  piho_check_image "$1"

  local DEV="$2"
  [ -n "$DEV" ] || DEV="$(piho_sd_device || true)"
  [ -n "$DEV" ] || fail "Could not auto detect SD card device"

  info "Using SD card device $DEV"

  piho_export "$1" "$PIHO_HOME/images/$1.img"

  debug "Ejecting disk $DEV"
  diskutil unmountDisk "$DEV" &> /dev/null ||
    fail "Failed to unmount disk $DEV"

  info "Flashing exported image to $DEV"
  sudo dd bs=1m "if=$PIHO_HOME/images/$1.img" "of=$DEV" 2> /dev/null ||
    fail "Failed to flash image to $DEV"

  debug "Removing exported image"
  rm -f "$PIHO_HOME/images/$1.img"

  info "Image $1 flashed to $DEV successfully"
}

# Copies files from the host into the image
piho_copy() {
  piho_check_image "$1"
  piho_init

  local NAME="$1"
  local DEST="${@: -1}"
  shift
  set -- "${@:1:$(($#-1))}" # pop $@

  info "Copying files into $NAME"
  mkdir -p "$PIHO_HOME/images/$NAME/upload"
  cp -r "$@" "$PIHO_HOME/images/$NAME/upload/"
  docker_exec piho container-copy "$NAME" "$DEST"
  rm -rf "$PIHO_HOME/images/$NAME/upload"
}

#
# Piho container commands
#

container_shell() {
  local NAME="$1"
  chroot_setup "$NAME"
  shift || true

  debug "Launching shell in chroot"
  local RET="0"
  chroot_run bash || {
    RET="$?"
    warn "Shell failed, rolling back changes"
  }
  chroot_cleanup "$NAME" "$RET"
  [ "$RET" = "0" ] || fail "Shell failed"
}

container_run() {
  local NAME="$1"
  chroot_setup "$NAME"
  shift

  debug "Running command in chroot"
  local RET="0"
  chroot_run "$@" || {
    RET="$?"
    warn "Command failed, rolling back changes"
  }
  chroot_cleanup "$NAME" "$RET"
  [ "$RET" = "0" ] || fail "Command failed"
}

container_copy() {
  chroot_setup "$1"
  debug "Copying files into image"
  shopt -s dotglob
  local RET="0"
  cp -r "$PIHO_HOME/images/$1/upload/"* "mount/$2" || {
    RET="$?"
    warn "Copy failed, rolling back changes"
  }
  chroot_cleanup "$1" "$RET"
  [ "$RET" = "0" ] || fail "Copy failed"
}

container_export() {
  debug "Copying cow image"
  cp "$PIHO_HOME/images/$1.qcow2" build.qcow2

  debug "Converting image"
  qemu-img convert -O raw build.qcow2 "$PIHO_HOME/images/$1.img"

  debug "Removing cow image"
  rm build.qcow2
}

container_debs_key() {
  apt-get install -y rng-tools
  rngd -r /dev/urandom -p /rng.pid
  cat <<EOF | gpg --gen-key --batch
Key-Type: RSA
Subkey-Type: RSA
Key-Length: 2048
Name-Real: pihotenuse debs
Name-Comment: pi on the hotenuse
Name-Email: hi@pihotenu.se
Expire-Date: 0
%no-ask-passphrase
%no-protection
%transient-key
%commit
EOF
  kill -9 "$(cat /rng.pid)"
  rm -rf rng.pid
  gpg --export -a > "$PIHO_DEBS_KEY_PUBLIC"
  gpg --export-secret-key -a > "$PIHO_DEBS_KEY_PRIVATE"
}

container_debs_index() {
  chroot_setup "debs"
  local RET="0"
  chroot_run piho chroot-debs-index "$@" || {
    RET="$?"
    warn "Index failed"
  }
  chroot_cleanup "debs" "1"
  [ "$RET" = "0" ] || fail "Index failed"
}

container_deb() {
  chroot_setup "debs"
  local RET="0"
  chroot_run piho chroot-deb "$@" || {
    RET="$?"
    warn "Deb build failed"
  }
  chroot_cleanup "debs" "1"
  [ "$RET" = "0" ] || fail "Deb build failed"
}

#
# Piho chroot commands
#

chroot_deb() {
  debs_import_key
  apt-get update
  debs_deb "$@"
  debs_index
}

chroot_debs_index() {
  debs_import_key
  debs_index
}

#
# Chroot helpers
#

# Finds and outputs the next free nbd device
chroot_nbd_dev() {
  local DEV=""
  for DEV in /sys/class/block/nbd* ; do
    [ "$(cat "$DEV/size")" = "0" ] || continue
    echo "/dev/$(basename "$DEV")"
    return 0
  done
  return 1
}

# Prepares the image for running inside the container
chroot_setup() {
  debug "Copying cow image"
  cp "$PIHO_HOME/images/$1.qcow2" build.qcow2

  debug "Getting next free nbd device"
  local NBD_DEV="$(chroot_nbd_dev || true)"

  [ -n "$NBD_DEV" ] || fail "Could not find a free nbd device"

  debug "Attaching nbd device $NBD_DEV"
  qemu-nbd -c "$NBD_DEV" build.qcow2 &> /dev/null

  debug "Determining partition offsets"
  local OFFSETS=($(fdisk -l "$NBD_DEV" | tail -2 | awk '{print $2}'))

  debug "Mounting image"
  mkdir -p mount
  mount -o offset=$((512*${OFFSETS[1]})) "$NBD_DEV" mount
  mount -o offset=$((512*${OFFSETS[0]})) "$NBD_DEV" mount/boot
  mount -t proc none mount/proc

  debug "Fixing hostname resolution for chroot"
  echo "127.0.1.1 $(hostname) #$PIHO_SENTINEL" >> mount/etc/hosts

  [ ! -f mount/etc/ld.so.preload ] || {
    debug "Disabling ld preloads for chroot"
    sed -i "s/^\\([^#]\\)/#$PIHO_SENTINEL \\1/" mount/etc/ld.so.preload
  }

  debug "Adding local debs apt source"
  echo "deb file:$PIHO_DEBS ./" > mount/etc/apt/sources.list.d/piho.list

  debug "Mounting piho home into chroot"
  mkdir -p mount/piho/home
  mount -o bind "$PIHO_HOME" mount/piho/home

  debug "Adding policy so no init services start in chroot"
  cat > mount/usr/sbin/policy-rc.d <<EOF
#!/bin/sh
exit 101
EOF
  chmod a+x mount/usr/sbin/policy-rc.d

  debug "Copying piho into chroot"
  mkdir -p mount/piho/bin
  cp "$(which piho)" mount/piho/bin

  debug "Adding piho to path inside chroot"
  echo 'PATH="/piho/bin:$PATH"' > /etc/profile.d/piho.sh

  debug "Copying qemu binary into chroot"
  cp "$(which qemu-arm-static)" mount/usr/bin

  [ -f "$PIHO_DEBS_KEY_PUBLIC" ] || return 0

  debug "Adding debs key to apt"
  chroot_run apt-key add "$PIHO_DEBS_KEY_PUBLIC" &> /dev/null
}

# Unprepares the image inside the container, optionally discarding changes
chroot_cleanup() {
  debug "Removing qemu binary"
  rm -f mount/usr/bin/qemu-arm-static
  
  debug "Removing piho from path in chroot"
  rm -f mount/etc/profile.d/piho.sh

  debug "Removing piho"
  rm -rf mount/piho/bin

  debug "Removing policy"
  rm -f mount/usr/sbin/policy-rc.d

  debug "Unmounting piho home"
  umount mount/piho/home
  rm -rf mount/piho

  debug "Removing apt source"
  rm -f mount/etc/apt/sources.list.d/piho.list

  [ ! -f mount/etc/ld.so.preload ] || {
    debug "Restoring ld preloads"
    sed -i "s/^#$PIHO_SENTINEL //" mount/etc/ld.so.preload
  }

  debug "Remove host hostname entry from chroot"
  sed -i "/$PIHO_SENTINEL/d" mount/etc/hosts

  # Save NBD_DEV before unmounting
  local NBD_DEV="$(mount | grep /dev/nbd | awk '{print $1}' | head -1)"
  
  debug "Unmounting image"
  umount mount/proc
  umount mount/boot
  umount mount

  debug "Detaching nbd device $NBD_DEV"
  qemu-nbd -d "$NBD_DEV" &> /dev/null

  [ "${2:-0}" = "0" ] || {
    debug "Removing modified cow image"
    rm -f build.qcow2
    return 0
  }

  debug "Moving modified cow image"
  mv build.qcow2 "$PIHO_HOME/images/$1.qcow2"
}

# Runs a command within the chroot - assumes chroot_setup has been called
chroot_run() {
  debug "Executing $@"
  chroot mount qemu-arm-static /bin/bash -c 'exec "$@"' hipo "$@"
}

#
# Deb helpers
#

# Initializes the host debs repo, at least enough so apt doesn't complain
debs_init() {
  debug "Creating debs folder"
  mkdir -p "$PIHO_DEBS"
  touch "$PIHO_DEBS/Packages"

  debug "Creating apt repo config"
  cat > "$PIHO_DEBS/Release.conf" <<EOF
APT::FTPArchive::Release::Origin "pihotenuse";
APT::FTPArchive::Release::Label "pihotenuse";
APT::FTPArchive::Release::Suite "stable";
APT::FTPArchive::Release::Codename "wheezy";
APT::FTPArchive::Release::Architectures "armhf";
APT::FTPArchive::Release::Components "main";
APT::FTPArchive::Release::Description "pi on the hotenuse";
EOF
}

# Imports the piho debs private key into the current gpg keychain
debs_import_key() {
  gpg -k &> /dev/null
  # Fails on double import and checking for a particular key sucks? oh, gpg
  gpg --allow-secret-key-import \
    --import "$PIHO_DEBS_KEY_PRIVATE" &> /dev/null || true
}

# Indexes packages in the apt repo, signing it with the current private key
debs_index() {
  pushd "$PIHO_DEBS"
  dpkg-scanpackages . | tee > Packages | gzip -9c > Packages.gz
  apt-ftparchive -c=Release.conf release . > Release
  gpg --yes -abs -o Release.gpg Release
  popd
}

# Same as dget minus x minus minus x
debs_dget() {
  local BASE="$(dirname $1)"
  local FILE="$(basename "${1%%\?*}")"
  local EXT="${FILE##*.}"
  [ -f "$FILE" ] || curl -LO "$1"
  [ "$EXT" = "dsc" ] || { tar -zxvf "$FILE" || return $? && return 0; }
  local DEPS=$(cat "$FILE" |
    sed -n '/^Files:/,/^\(\S\|$\)/{/^\s/{s/^.*\s\(\S*\)$/\1/ p}}')
  local DEP
  for DEP in $DEPS; do
    [ -f "$DEP" ] || curl -LO "$BASE/$DEP" || return $?
  done
  dpkg-source -x --no-check "$FILE"
}

# Kinda like py2dsc except accepts URLs and git repos (with branch names!)
debs_pyget() {
  local URL="${1%%#*}"
  if [ "${URL##*.}" = "git" ]; then
    [ "${1##*#}" = "$1" ] || local BRANCH="--branch ${1##*#}"
    git clone $BRANCH "$URL" src
    pushd src
    python setup.py --command-packages stdeb.command sdist_dsc --dist-dir=..
    popd
    rm -rf src
  else
    curl -LO "$1" && py2dsc --dist-dir . "$(basename "${URL%%\?*}")"
  fi
}

# Extracts build dependencies and installs them
debs_deps() {
  # TODO: there must be a better way...
  local DEPS=$(dpkg-checkbuilddeps 2>&1 | sed \
    -e 's/.*dependencies: //' \
    -e 's/ ([^)]*)//g' \
    -e 's/,//g' \
    -e 's/| [^ ]* //g' || true)
  local DEP
  for DEP in $DEPS; do
    dpkg -s "$DEP" 2> /dev/null | grep -q "Status: install ok installed" ||
      apt-get install -y "$DEP"
  done
}

# Builds a deb package
debs_deb() {
  local NAME="$1"
  local URL="$2"
  local PATCH="$3"
  local OPTS="$4"
  local FETCH="${5:-"debs_dget"}"

  mkdir -p "/tmp/$NAME"
  pushd "/tmp/$NAME"
  "$FETCH" "$URL"
  pushd "$(find . -mindepth 1 -maxdepth 1 -type d -not -name '*.orig')"
  [ -z "$PATCH" ] || bash -c "$PATCH"
  debs_deps
  DEB_BUILD_OPTIONS="$OPTS" dpkg-buildpackage -us -uc
  popd
  popd
  mkdir -p "$PIHO_DEBS/$NAME"
  mv "/tmp/$NAME/"*.deb "$PIHO_DEBS/$NAME"
  rm -rf "/tmp/$NAME"
}

#
# Piho main
#

piho_main() {
  local CMD="$1"
  shift || true

  case "$CMD" in

    # Global Commands
    "init")           piho_init "$@" ;;
    "list"    |"ls")  piho_list ;;
    "upgrade" |"up")  piho_upgrade ;;
    "version" |"v")   echo "$PIHO_VERSION" ;;
    "update")         piho_update ;;

    "boot2docker"|"b2d")
      b2d_init
      exec boot2docker "$@"
      ;;
      
    "docker"|"doc")
      b2d_init
      docker_init
      exec docker "$@"
      ;;

    # Image Commands
    "create"|"c")   piho_create "$@" ;;
    "clone" |"cl")  piho_clone "$@" ;;
    "remove"|"rm")  piho_remove "$@" ;;
    "export"|"x")   piho_export "$@" ;;
    "flash" |"f")   piho_flash "$@" ;;
    "shell" |"sh")  piho_shell "$@" ;;
    "run"   |"r")   piho_run "$@" ;;
    "copy"  |"cp")  piho_copy "$@" ;;

    # Deb Pkg Commands
    "deb"   |"d")   piho_deb "$@" ;;
    "pydeb" |"pd")  piho_pydeb "$@" ;;

    # Apt Repo Commands
    "index" |"di")  piho_index "$@" ;;
    "debs"  |"ds")  piho_debs "$@" ;;

    # Container commands (private)
    "container-shell")      container_shell "$@" ;;
    "container-run")        container_run "$@" ;;
    "container-copy")       container_copy "$@" ;;
    "container-export")     container_export "$@" ;;
    "container-debs-key")   container_debs_key "$@" ;;
    "container-deb")        container_deb "$@" ;;
    "container-debs-index") container_debs_index "$@" ;;

    # Chroot commands (private)
    "chroot-deb")        chroot_deb "$@" ;;
    "chroot-debs-index") chroot_debs_index "$@" ;;

    # Installer
    "install") piho_install "$@" ;;

    # Default shows help
    *)
      piho_banner
      echo -e "
Global Commands:    ${GRAY}command [args...]${RESET}
  ${CYAN}init${RESET}              Initialize pihotenuse environment
  ${CYAN}list${RESET}         (${RED}ls${RESET}) List available images
  ${CYAN}boot2docker${RESET} (${RED}b2d${RESET}) Execute a boot2docker command using the pihotenuse profile
  ${CYAN}docker${RESET}      (${RED}doc${RESET}) Execute a docker command using the pihotenuse docker image
  ${CYAN}version${RESET}       (${RED}v${RESET}) Display pihotenuse version
  ${CYAN}upgrade${RESET}      (${RED}up${RESET}) Upgrade piho to the latest available version
  ${CYAN}update${RESET}            Update docker container to currently running piho version

Image Commands:     ${GRAY}command <image-name> [args...]${RESET}
  ${CYAN}create${RESET}        (${RED}c${RESET}) Create a new image
  ${CYAN}clone${RESET}        (${RED}cl${RESET}) Clone an existing image
  ${CYAN}remove${RESET}       (${RED}rm${RESET}) Remove an image
  ${CYAN}export${RESET}        (${RED}x${RESET}) Export a raw image to be flashed
  ${CYAN}flash${RESET}         (${RED}f${RESET}) Write an image to an SD card
  ${CYAN}shell${RESET}        (${RED}sh${RESET}) Open an interactive shell in an image
  ${CYAN}run${RESET}           (${RED}r${RESET}) Run a command in an image
  ${CYAN}copy${RESET}         (${RED}cp${RESET}) Copy files into an image

Deb Pkg Commands:   ${GRAY}command <pkg-name> [args...]${RESET}
  ${CYAN}deb${RESET}           (${RED}d${RESET}) Build or add a deb to the local apt repo
  ${CYAN}pydeb${RESET}        (${RED}pd${RESET}) Build a python deb from a sdist tarball

Apt Repo Commands:  ${GRAY}command [args...]${RESET}
  ${CYAN}debs${RESET}         (${RED}ds${RESET}) List all debs in the local apt repo
  ${CYAN}index${RESET}        (${RED}di${RESET}) Update the debs package index
"
      ;;
  esac
}

# Allow piho to be sourced without running main
[ "${BASH_SOURCE[0]}" != "$0" ] || piho_main "$@"
