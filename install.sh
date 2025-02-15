#!/usr/bin/env bash

set -euo pipefail

RED='\033[0;31m'
ORANGE='\033[0;33m'
NC='\033[0m'
# Put your package manager and arguments for installing without confirmation and skipping already installed packages here.
PKGMAN=()
# The script will try to look for the following if $PKGMAN is empty and use the first one along with arguments:
SUPPORTED_HELPERS=(yay paru trizen)
HELPER_ARGS=(-S --noconfirm --needed)
# The script will panic if none of the following kernels are installed.
SUPPORTED_KERNELS=(linux linux-lts linux-zen linux-hardened)

# PKGBUILD build and install command.
MAKEPKG=(makepkg -si --noconfirm --needed)
# Main package fix directory (will be installed when $FLAG_INSTALL_STABLE is false. Default).
PKG_FIX_DIR=package-fix
# Stable package fix directory (will be installed if $FLAG_INSTALL_STABLE is true).
PKG_FIX_STABLE_DIR=package-fix-stable
# Script flags, best to leave them unless you want to 'hardcode' behaviours.
FLAG_INSTALL_STABLE=false
FLAG_YUY2_WA=false
FLAG_S2DISK_HACK=false
FLAG_EXPLICIT_WAYLAND=false
FLAG_REBOOT_AFTER_INSTALL=false
FLAG_QUIET_MODE=false

INSTALLED_PKG_LIST=ipu6-pkgs.txt
# Dependencies to be installed, particularly GStreamer plugins, to be installed first. These won't be uninstalled later.
DEP_PKGS=(base-devel
          gst-plugin-pipewire
          gst-plugins-good
)

# All packages installed, in order.
# These packages will be written down to $INSTALLED_PKG_LIST which will be then used by uninstall.sh
PKGS=(intel-ipu6-dkms-git
      intel-ipu6-camera-bin # Has to be kept in index 1
      intel-ipu6-camera-hal-git # Has to be kept in index 2. Gotta come up with cleaner way to do this.
      v4l2loopback-dkms-git
      v4l2-relayd
)

error() {
  printf "${RED}%s${NC} %s\n" "ERROR:" "${1}"
  exit 1
}

warn() {
  printf "${ORANGE}%s${NC} %s\n" "WARNING:" "${1}"
}

# Configure package manager here if necessary:
if [[ "${#PKGMAN[@]}" -eq 0 ]]; then
  helper_exists=false
  for helper in "${SUPPORTED_HELPERS[@]}"; do
    if [[ -x "$(command -v "$helper")" ]]; then
      PKGMAN=("$helper" "${HELPER_ARGS[@]}")
      helper_exists=true
    fi
  done
  $helper_exists || error "Couldn't find a package manager, please install any of these helpers: ${SUPPORTED_HELPERS[*]}"
fi

# Figure out the Intel chipset generation through /proc/cpuinfo
_cpuinfo="$(cat /proc/cpuinfo)"
[ -n "${_cpuinfo}" ] || error "Cannot read /proc/cpuinfo"
if [[ "$_cpuinfo" =~ "11th" ]]; then
  echo "# Detected Tiger Lake (11th generation)."
  PKGS[1]=intel-ipu6-camera-bin
  PKGS[2]=intel-ipu6-camera-hal-git
elif [[ "$_cpuinfo" =~ "12th" ]] || [[ "$_cpuinfo" =~ "13th" ]]; then
  PKGS[1]=intel-ipu6ep-camera-bin
  PKGS[2]=intel-ipu6ep-camera-hal-git
elif [[ "$_cpuinfo" =~ "14th" ]]; then
  # Now time to figure out whether it's Raptor Lake Refresh or Meteor Lake
  _cpugen="$(cat /sys/devices/cpu_core/caps/pmu_name)"
  if [[ "$_cpugen" =~ "raptor" ]]; then
    PKGS[1]=intel-ipu6ep-camera-bin
    PKGS[2]=intel-ipu6ep-camera-hal-git
  elif [[ "$_cpugen" =~ "meteor" ]]; then
    PKGS[1]=intel-ipu6epmtl-camera-bin
    PKGS[2]=intel-ipu6epmtl-camera-hal-git
  else
    error "Unknown Intel chipset generation. Please report this to the maintainer."
  fi
else
  warn "Unknown Intel chipset generation. Please report this to the maintainer."
fi


# Builds the package if a directory with a PKGBUILD is found, or installs it from the AUR/repos if not.
build_and_install() {
  local pkg="${1}"
  local pkg_dir="${PKG_FIX_DIR}"
  $FLAG_INSTALL_STABLE && pkg_dir="${PKG_FIX_STABLE_DIR}"
  if [ -e "${pkg_dir}/${pkg}/PKGBUILD" ]; then
    echo "# Build and install package: ${1}"
    pushd "${pkg_dir}/${pkg}" || error "Somehow unable to go to directory: ${pkg}"
    "${MAKEPKG[@]}" || error "Failed to build/install: ${pkg}"
    popd || error "Unable to go back to working directory."
    echo "=> SUCCESS"
  else
    echo "# Install package from the AUR/repos: ${pkg}"
    if "${PKGMAN[@]}" "${pkg}"; then
      echo "=> SUCCESS"
    else
      if pacman -Qq "${pkg}"; then
        warn "Package failed to install, but is already installed. Trying to continue."
      else
        error "Couldn't find/unable to install: ${pkg}"
      fi
    fi
  fi
}

# ------------------------------------------------------------------------------
# Handles options
while getopts ":abcgswrqh" opt; do
  case $opt in
    a)
      echo "Workaround for other applications will be installed."
      FLAG_YUY2_WA=true
      ;;
    b)
      echo "Workaround for other applications will be installed."
      FLAG_YUY2_WA=true
      ;;
    c)
      echo "Workaround for other applications will be installed."
      FLAG_YUY2_WA=true
      ;;
    g)
      echo "Workaround for other applications will be installed."
      FLAG_YUY2_WA=true
      ;;
    s)
      echo "Hibernation workaround will be installed."
      FLAG_S2DISK_HACK=true
      ;;
    w)
      echo "Installing GST plugins for Wayland."
      FLAG_EXPLICIT_WAYLAND=true
      ;;
    r)
      echo "System will reboot after installation."
      FLAG_REBOOT_AFTER_INSTALL=true
      ;;
    q)
      echo "Quiet mode enabled. No installation messages will be printed."
      FLAG_QUIET_MODE=true
      ;;
    h)
      echo "Usage: ${0} [options]"
      echo "Options:"
      echo "  -a                  Install workaround for other applications."
      echo "  -b                  Install main fix packages. (default)"
      echo "  -a                  Install stable fix packages."
      echo "  -g <{tgl|adl|mtl}>  Choose your Intel chipset generation (11th-14th generation):"
      echo "                         '-g tgl' for Tiger Lake (11th generation)."
      echo "                         '-g adl' for Alder Lake (12th), Raptor Lake (13th), and Raptor Lake Refresh (14th)."
      echo "                         '-g mtl' for Meteor Lake (14th). When in doubt, use 'adl' instead."
      #echo "                         The script has detected you are using"
      echo "  -s                 Install workaround for hibernation."
      echo "  -w                 Install GST plugins (bad) for Wayland. Only needed to specify if installing from the TTY."
      echo "                     Normally, the script will check \$XDG_SESSION_TYPE to determine if Wayland is used."
      echo "                     Right now, you are on '${XDG_SESSION_TYPE}'. If this is empty and you are going to use a Wayland DE, use this option."
      echo "  -r                 Reboot after installation. Not recommended unless success is guaranteed."
      echo "  -q                 Quiet mode by not printing builds and installs. Also not recommended. (Currently not working.)"
      echo "  -h                 Show this help message."
      exit 0
      ;;
    \?)
      echo "Invalid option -$OPTARG" >&2
      echo "Try '${0} -h' for usage." >&2
      exit 1
      ;;
  esac
done

# Need to have the correct headers installed before proceding with DKMS
kernel_exists=false
for kernel in "${SUPPORTED_KERNELS[@]}"; do
  if pacman -Qq "${kernel}" 1>/dev/null 2>&1; then
    echo "# Install headers for: ${kernel}"
    build_and_install "${kernel}-headers"
    kernel_exists=true
  fi
done
$kernel_exists || error "No supported kernel found. Please install one of the following: ${SUPPORTED_KERNELS[*]}"

# Check if Wayland is used
if $FLAG_EXPLICIT_WAYLAND || [ "${XDG_SESSION_TYPE}" = "wayland" ]; then
  echo "# Wayland detected or explicitly requested. Installing 'gst-plugins-bad'."
  DEP_PKGS+=(gst-plugins-bad)
fi

echo "# Installing dependencies."
# Install all dependencies first
for pkg in "${DEP_PKGS[@]}"; do
  build_and_install "${pkg}"
done

echp "# Installing the camera stack."
echo > "${INSTALLED_PKG_LIST}"
# Install all packages in order
for pkg in "${PKGS[@]}"; do
  build_and_install "${pkg}"
  echo "${pkg}" >> "${INSTALLED_PKG_LIST}"
done

# Copy workarounds if requested
$FLAG_S2DISK_HACK && sudo install -m 744 workarounds/i2c_ljca-s2disk.sh /usr/lib/systemd/system-sleep/i2c_ljca-s2disk.sh
if $FLAG_YUY2_WA; then
  sudo mkdir -p /etc/systemd/system/v4l2-relayd.service.d
  sudo cp -f workarounds/override.conf /etc/systemd/system/v4l2-relayd.service.d/override.conf
fi

echo "# Enable: v4l2-relayd.service"
if sudo systemctl enable v4l2-relayd.service; then
  echo "=> SUCCESS"
else
  error "Failed to enable: v4l2-relayd.service"
fi
echo "# Start: v4l2-relayd.service"
if sudo systemctl start v4l2-relayd.service; then
  echo "=> SUCCESS"
else
  error "Failed to start: v4l2-relayd.service"
fi

if ! $FLAG_REBOOT_AFTER_INSTALL; then
  echo -e "\n\nAll done.\nRemember to reboot upon succesful installation!"
  read -r -p "Reboot now? [y/N] " ans
  if [ "$ans" = "Y" ] || [ "$ans" = "y" ]; then
    FLAG_REBOOT_AFTER_INSTALL=true
  fi
fi

if $FLAG_REBOOT_AFTER_INSTALL; then
  echo "# Rebooting in 5 seconds..."
  sleep 5
  reboot
else
  echo "# Don't forget to reboot!"
  exit 0
fi
