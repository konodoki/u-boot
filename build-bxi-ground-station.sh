#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0+
# Build U-Boot for the BXI Ground Station RK3566 board.

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
RK_BIN_DIR=${RK_BIN_DIR:-"$(dirname "$SCRIPT_DIR")/rkbin"}
OUTPUT_DIR=${OUTPUT_DIR:-"$SCRIPT_DIR/build/bxi-ground-station"}
CROSS_COMPILE=${CROSS_COMPILE:-aarch64-linux-gnu-}
JOBS=${JOBS:-$(nproc)}
DEFCONFIG=bxi-ground-station-rk3566_defconfig
TEE_SOURCE=${TEE:-}
TEE_LOAD_ADDR=${TEE_LOAD_ADDR:-0x08400000}
SPI_NOR_SIZE=${SPI_NOR_SIZE:-0x400000}
LUBANCAT_UBOOT_DIR=${LUBANCAT_UBOOT_DIR:-"$(dirname "$SCRIPT_DIR")/LubanCat_SDK/u-boot"}
USBPLUG_BUILD_DIR=${USBPLUG_BUILD_DIR:-"$SCRIPT_DIR/build/rk3568-usbplug-official"}

CLEAN=0
WITH_TEE=1
BUILD_RKDEVTOOL_LOADER=0

usage() {
	cat <<USAGE
Usage: $(basename "$0") [options]

Build U-Boot for the BXI Ground Station RK3566 board.
The script clones rkbin when needed and includes its RK3568 BL32/OP-TEE
binary by default.

Options:
  -c, --clean       Remove the output directory before building
  -j, --jobs N      Number of parallel build jobs (default: $JOBS)
      --tee FILE    Use an explicit OP-TEE/BL32 image instead of rkbin
      --no-tee      Build without OP-TEE
      --rkdevtool-loader
                    Also build the official RKDevTool Loader using the
                    vendor rk3568-usbplug.config without local modifications
  -h, --help        Show this help

Environment overrides:
  RK_BIN_DIR        rkbin directory (default: $RK_BIN_DIR)
  OUTPUT_DIR        build output directory (default: $OUTPUT_DIR)
  CROSS_COMPILE     toolchain prefix (default: $CROSS_COMPILE)
  ROCKCHIP_TPL      explicit Rockchip DDR binary path
  BL31              explicit ARM Trusted Firmware BL31 path
  TEE               explicit OP-TEE/BL32 source image path
  TEE_LOAD_ADDR     raw Rockchip BL32 load address (default: $TEE_LOAD_ADDR)
  SPI_NOR_SIZE       SPI NOR capacity in bytes (default: $SPI_NOR_SIZE)
  LUBANCAT_UBOOT_DIR vendor U-Boot used to build USBPlug
                     (default: $LUBANCAT_UBOOT_DIR)
  USBPLUG_BUILD_DIR  USBPlug temporary build directory
                     (default: $USBPLUG_BUILD_DIR)
  RKDEVTOOL_DDR      explicit RKDevTool DDR initialization binary
  RKDEVTOOL_SPL      explicit RKDevTool FlashBoot/SPL binary
  JOBS               number of parallel jobs
USAGE
}

while (($#)); do
	case "$1" in
	-c|--clean)
		CLEAN=1
		shift
		;;
	-j|--jobs)
		if (($# < 2)); then
			echo "error: $1 requires a value" >&2
			exit 2
		fi
		JOBS=$2
		shift 2
		;;
	--tee)
		if (($# < 2)); then
			echo "error: $1 requires a file path" >&2
			exit 2
		fi
		TEE_SOURCE=$2
		WITH_TEE=1
		shift 2
		;;
	--tee=*)
		TEE_SOURCE=${1#*=}
		WITH_TEE=1
		shift
		;;
	--no-tee)
		WITH_TEE=0
		TEE_SOURCE=
		shift
		;;
	--rkdevtool-loader)
		BUILD_RKDEVTOOL_LOADER=1
		shift
		;;
	-h|--help)
		usage
		exit 0
		;;
	*)
		echo "error: unknown option: $1" >&2
		usage >&2
		exit 2
		;;
	esac
done

if ! [[ $JOBS =~ ^[1-9][0-9]*$ ]]; then
	echo "error: JOBS must be a positive integer: $JOBS" >&2
	exit 2
fi

if ! [[ $TEE_LOAD_ADDR =~ ^0[xX][0-9a-fA-F]+$ ]]; then
	echo "error: TEE_LOAD_ADDR must be hexadecimal: $TEE_LOAD_ADDR" >&2
	exit 2
fi

if ! [[ $SPI_NOR_SIZE =~ ^(0[xX][0-9a-fA-F]+|[1-9][0-9]*)$ ]]; then
	echo "error: SPI_NOR_SIZE must be a positive integer: $SPI_NOR_SIZE" >&2
	exit 2
fi

missing=()
for command in git make "${CROSS_COMPILE}gcc" python3 bison flex swig; do
	if ! command -v "$command" >/dev/null 2>&1; then
		missing+=("$command")
	fi
done

if ((${#missing[@]})); then
	echo "error: missing required commands: ${missing[*]}" >&2
	echo >&2
	cat >&2 <<'PACKAGES'
On Ubuntu, install the build dependencies with:
  sudo apt update
  sudo apt install -y \
    build-essential gcc-aarch64-linux-gnu bc bison flex swig \
    device-tree-compiler libssl-dev libgnutls28-dev libncurses-dev \
    python3 python3-dev python3-setuptools python3-pyelftools \
    python3-jsonschema python3-yaml pkg-config git
PACKAGES
	exit 1
fi

if ((BUILD_RKDEVTOOL_LOADER)); then
	if [[ ! -f $LUBANCAT_UBOOT_DIR/configs/rockchip-usbplug_defconfig ||
	      ! -f $LUBANCAT_UBOOT_DIR/configs/rk3568-usbplug.config ]]; then
		echo "error: LubanCat vendor U-Boot was not found at:" >&2
		echo "       $LUBANCAT_UBOOT_DIR" >&2
		echo "       Set LUBANCAT_UBOOT_DIR to the vendor U-Boot source tree." >&2
		exit 1
	fi
fi

if [[ ! -d $RK_BIN_DIR ]]; then
	echo "==> Cloning Rockchip rkbin into $RK_BIN_DIR"
	git clone --depth 1 https://github.com/rockchip-linux/rkbin.git "$RK_BIN_DIR"
elif [[ ! -d $RK_BIN_DIR/bin/rk35 ]]; then
	echo "error: $RK_BIN_DIR exists but does not contain bin/rk35" >&2
	exit 1
fi

pick_firmware() {
	local requested=$1
	local preferred=$2
	local pattern=$3
	local description=$4
	local candidate

	if [[ -n $requested ]]; then
		candidate=$requested
	elif [[ -f $preferred ]]; then
		candidate=$preferred
	else
		candidate=$(find "$RK_BIN_DIR/bin/rk35" -maxdepth 1 -type f \
			-name "$pattern" -print | sort -V | tail -n 1)
	fi

	if [[ -z $candidate || ! -f $candidate ]]; then
		echo "error: unable to find $description in $RK_BIN_DIR/bin/rk35" >&2
		echo "       Set the corresponding environment variable to an explicit file." >&2
		exit 1
	fi

	realpath "$candidate"
}

prepare_tee_image() {
	local source=$1
	local output=$2
	local load_addr=$3

	python3 - "$source" "$output" "$load_addr" <<'PY'
from pathlib import Path
import shutil
import struct
import sys

source = Path(sys.argv[1])
output = Path(sys.argv[2])
load_addr = int(sys.argv[3], 0)
data = source.read_bytes()

if data.startswith(b'\x7fELF'):
    image_format = 'ELF'
    shutil.copyfile(source, output)
elif data.startswith(b'OPTE\x01'):
    image_format = 'OP-TEE v1 binary'
    shutil.copyfile(source, output)
else:
    # Rockchip rkbin distributes RK3568 OP-TEE as a raw BL32 binary. Binman
    # needs the OP-TEE v1 header to learn its load and entry addresses.
    header = struct.pack(
        '<4sBBHIIIII',
        b'OPTE', 1, 1, 0,
        len(data),
        load_addr >> 32,
        load_addr & 0xffffffff,
        len(data),
        0,
    )
    output.write_bytes(header + data)
    image_format = f'raw BL32 wrapped as OP-TEE v1 at {load_addr:#x}'

print(image_format)
PY
}

ROCKCHIP_TPL=$(pick_firmware \
	"${ROCKCHIP_TPL:-}" \
	"$RK_BIN_DIR/bin/rk35/rk3568_ddr_1560MHz_v1.13.bin" \
	'rk3568_ddr_*.bin' \
	'RK3568/RK3566 DDR TPL binary')

BL31=$(pick_firmware \
	"${BL31:-}" \
	"$RK_BIN_DIR/bin/rk35/rk3568_bl31_v1.34.elf" \
	'rk3568_bl31_v*.elf' \
	'RK3568/RK3566 BL31 firmware')

if ((WITH_TEE)); then
	TEE_SOURCE=$(pick_firmware \
		"$TEE_SOURCE" \
		"$RK_BIN_DIR/bin/rk35/rk3568_bl32_v2.18.bin" \
		'rk3568_bl32_v*.bin' \
		'RK3568/RK3566 BL32/OP-TEE firmware')
fi

if ((CLEAN)); then
	echo "==> Removing $OUTPUT_DIR"
	rm -rf -- "$OUTPUT_DIR"
	if ((BUILD_RKDEVTOOL_LOADER)); then
		echo "==> Removing $USBPLUG_BUILD_DIR"
		rm -rf -- "$USBPLUG_BUILD_DIR"
	fi
fi

mkdir -p "$OUTPUT_DIR"

tee_arg=()
if ((WITH_TEE)); then
	TEE_IMAGE="$OUTPUT_DIR/tee.bin"
	TEE_FORMAT=$(prepare_tee_image "$TEE_SOURCE" "$TEE_IMAGE" "$TEE_LOAD_ADDR")
	TEE_STATUS="$TEE_IMAGE"
	tee_arg+=("TEE=$TEE_IMAGE")
else
	TEE_FORMAT="disabled"
	TEE_STATUS="disabled (--no-tee)"
fi

cat <<INFO
==> BXI Ground Station build configuration
    Source:       $SCRIPT_DIR
    Output:       $OUTPUT_DIR
    Toolchain:    $CROSS_COMPILE
    Jobs:         $JOBS
    DDR TPL:      $ROCKCHIP_TPL
    BL31:         $BL31
    SPI NOR:      $SPI_NOR_SIZE bytes
    OP-TEE:       $TEE_STATUS
    TEE format:   $TEE_FORMAT
INFO

if ((WITH_TEE)); then
	echo "    TEE source:   $TEE_SOURCE"
fi

make -C "$SCRIPT_DIR" \
	O="$OUTPUT_DIR" \
	CROSS_COMPILE="$CROSS_COMPILE" \
	"${tee_arg[@]}" \
	"$DEFCONFIG"

make -C "$SCRIPT_DIR" \
	O="$OUTPUT_DIR" \
	CROSS_COMPILE="$CROSS_COMPILE" \
	ROCKCHIP_TPL="$ROCKCHIP_TPL" \
	BL31="$BL31" \
	"${tee_arg[@]}" \
	-j"$JOBS"

if ((BUILD_RKDEVTOOL_LOADER)); then
	echo
	echo "==> Building official RKDevTool USBPlug"

	RKDEVTOOL_DDR=$(pick_firmware \
		"${RKDEVTOOL_DDR:-}" \
		"$RK_BIN_DIR/bin/rk35/rk3566_ddr_1056MHz_v1.26.bin" \
		'rk3566_ddr_*.bin' \
		'RK3566 RKDevTool DDR initialization binary')

	RKDEVTOOL_SPL=$(pick_firmware \
		"${RKDEVTOOL_SPL:-}" \
		"$RK_BIN_DIR/bin/rk35/rk356x_spl_v1.14.bin" \
		'rk356x_spl_v*.bin' \
		'RK356x RKDevTool FlashBoot/SPL binary')

	BOOT_MERGER="$RK_BIN_DIR/tools/boot_merger"
	if [[ ! -x $BOOT_MERGER ]]; then
		echo "error: boot_merger was not found at $BOOT_MERGER" >&2
		exit 1
	fi

	# Start from the vendor's official USBPlug configuration.  Do not alter
	# .config or dt.dtb here: the Loader must remain the official build.
	mkdir -p "$USBPLUG_BUILD_DIR"
	make -C "$LUBANCAT_UBOOT_DIR" \
		O="$USBPLUG_BUILD_DIR" \
		CROSS_COMPILE="$CROSS_COMPILE" \
		rockchip-usbplug_defconfig rk3568-usbplug.config
	make -C "$LUBANCAT_UBOOT_DIR" \
		O="$USBPLUG_BUILD_DIR" \
		CROSS_COMPILE="$CROSS_COMPILE" \
		olddefconfig
	make -C "$LUBANCAT_UBOOT_DIR" \
		O="$USBPLUG_BUILD_DIR" \
		CROSS_COMPILE="$CROSS_COMPILE" \
		-j"$JOBS" usbplug.bin

	USBPLUG_IMAGE="$USBPLUG_BUILD_DIR/usbplug.bin"
	if [[ ! -f $USBPLUG_IMAGE ]]; then
		echo "error: official USBPlug was not generated: $USBPLUG_IMAGE" >&2
		exit 1
	fi

	PACK_DIR="$USBPLUG_BUILD_DIR/pack"
	mkdir -p "$PACK_DIR"
	cp "$BOOT_MERGER" "$PACK_DIR/boot_merger"
	chmod +x "$PACK_DIR/boot_merger"

	RKDEVTOOL_LOADER="$OUTPUT_DIR/rk356x_loader_v1.26.114.bin"
	cat > "$PACK_DIR/RK3566MINIALL-OFFICIAL.ini" <<EOF
[CHIP_NAME]
NAME=RK3568
[VERSION]
MAJOR=1
MINOR=1
[CODE471_OPTION]
NUM=1
Path1=$RKDEVTOOL_DDR
Sleep=1
[CODE472_OPTION]
NUM=1
Path1=$USBPLUG_IMAGE
[LOADER_OPTION]
NUM=2
LOADER1=FlashData
LOADER2=FlashBoot
FlashData=$RKDEVTOOL_DDR
FlashBoot=$RKDEVTOOL_SPL
[OUTPUT]
PATH=$RKDEVTOOL_LOADER
[SYSTEM]
NEWIDB=true
[FLAG]
471_RC4_OFF=true
RC4_OFF=true
EOF

	(
		cd "$PACK_DIR"
		./boot_merger ./RK3566MINIALL-OFFICIAL.ini
	)

	if [[ ! -f $RKDEVTOOL_LOADER ]]; then
		echo "error: official RKDevTool Loader was not generated" >&2
		exit 1
	fi

	printf '    Official USBPlug:          %s (%s bytes)\n' \
		"$USBPLUG_IMAGE" "$(stat -c '%s' "$USBPLUG_IMAGE")"
	printf '    Official RKDevTool Loader: %s (%s bytes)\n' \
		"$RKDEVTOOL_LOADER" "$(stat -c '%s' "$RKDEVTOOL_LOADER")"
fi

SPI_IMAGE="$OUTPUT_DIR/u-boot-rockchip-spi.bin"
if [[ -f $SPI_IMAGE ]]; then
	# Keep SPI firmware and both persistent environment erase regions apart.
	# Read the generated config so validation follows the board's real layout.
	python3 - "$OUTPUT_DIR/.config" "$SPI_IMAGE" "$SPI_NOR_SIZE" <<'PY_SPI_LAYOUT'
from pathlib import Path
import sys

config_path, image_path, capacity = sys.argv[1:]
config = dict(line.split('=', 1) for line in Path(config_path).read_text().splitlines()
              if line.startswith('CONFIG_') and '=' in line)
capacity = int(capacity, 0)
image_size = Path(image_path).stat().st_size


def fail(message):
    sys.exit(f'error: invalid SPI NOR layout: {message}')


if config.get('CONFIG_ENV_IS_IN_SPI_FLASH') != 'y':
    fail('SPI flash environment is not enabled')
if config.get('CONFIG_ENV_REDUNDANT') != 'y':
    fail('redundant environment is not enabled')

try:
    size = int(config['CONFIG_ENV_SIZE'], 0)
    sector = int(config['CONFIG_ENV_SECT_SIZE'], 0)
    offsets = [int(config[name], 0) for name in
               ('CONFIG_ENV_OFFSET', 'CONFIG_ENV_OFFSET_REDUND')]
except (KeyError, ValueError) as exc:
    fail(f'missing or invalid environment configuration: {exc}')

if size <= 0 or sector <= 0:
    fail('environment and sector sizes must be positive')
erase_size = (size + sector - 1) // sector * sector
for offset in offsets:
    if offset < 0 or offset % sector:
        fail(f'environment offset {offset:#x} is not sector-aligned')
    if offset + erase_size > capacity:
        fail(f'environment at {offset:#x} exceeds flash capacity {capacity:#x}')
if abs(offsets[1] - offsets[0]) < erase_size:
    fail('the two environment erase regions overlap')
firmware_limit = min(offsets)
if image_size > firmware_limit:
    fail(f'firmware is {image_size} bytes, but must not exceed '
         f'{firmware_limit:#x}; it would overwrite the environment')

print(f'    SPI firmware: {image_size} bytes; limit: {firmware_limit:#x}')
print(f'    Environment:  {size:#x} bytes each at '
      f'{offsets[0]:#x} and {offsets[1]:#x}')
print(f'    Free before environment: {firmware_limit - image_size} bytes')
PY_SPI_LAYOUT
fi

echo
echo "==> Build complete"
for image in \
	u-boot-rockchip.bin \
	u-boot-rockchip-spi.bin \
	idbloader.img \
	u-boot.itb \
	tee.bin \
	rk356x_loader_v1.26.114.bin; do
	if [[ -f $OUTPUT_DIR/$image ]]; then
		printf '    %-28s %s\n' "$image" "$(du -h "$OUTPUT_DIR/$image" | cut -f1)"
	fi
done
