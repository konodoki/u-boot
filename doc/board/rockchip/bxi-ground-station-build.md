# bxi-ground-station 编译与 eMMC 镜像制作

本文档适用于自研 **RK3566 bxi-ground-station** 板。

当前启动方案：

```text
32 Mbit SPI NOR
├── Rockchip SPI 镜像：DDR TPL + SPL + U-Boot FIT
├── 0x3e0000：环境变量副本 A，64 KiB
└── 0x3f0000：环境变量副本 B，64 KiB

2 GiB eMMC 用户区
├── GPT
├── 分区1：FAT32 boot
└── 分区2：ext4 rootfs
```

**U-Boot 放在 SPI NOR，系统文件放在 eMMC。** 因此，eMMC 镜像中不再放
`u-boot-rockchip-spi.bin`。

## 1. 相关脚本和目录

在 U-Boot 源码目录 `/home/konodoki/u-boot` 下：

```text
build-bxi-ground-station.sh   编译 U-Boot、SPI 镜像和可选的 RKDevTool Loader
make-bxi-emmc-image.sh        制作 eMMC GPT + boot + rootfs 镜像
build/bxi-ground-station/     所有编译输出
```

脚本默认使用：

```text
板名：       bxi-ground-station
芯片：       RK3566
DDR：        rk3568_ddr_1560MHz_v1.13.bin
BL31：       rk3568_bl31_v1.34.elf
TEE：        rk3568_bl32_v2.18.bin（默认自动使用 rkbin 中的文件）
SPI NOR：    4 MiB（32 Mbit）
SPI 速度：   24 MHz
```

如果实际 DDR 颗粒或时序与默认 TPL 不匹配，应通过 `ROCKCHIP_TPL` 指定适合本板的 DDR 文件。

## 2. 安装 U-Boot 编译依赖

```bash
sudo apt update
sudo apt install -y \
    build-essential gcc-aarch64-linux-gnu bc bison flex swig \
    device-tree-compiler libssl-dev libgnutls28-dev libncurses-dev \
    python3 python3-dev python3-setuptools python3-pyelftools \
    python3-jsonschema python3-yaml pkg-config git
```

编译脚本默认会自动下载 Rockchip 固件仓库：

```text
/home/konodoki/rkbin
```

也可以手动准备：

```bash
cd /home/konodoki
[ -d rkbin ] || git clone --depth 1 \
    https://github.com/rockchip-linux/rkbin.git
```

## 3. 编译 U-Boot

### 3.1 普通编译

```bash
cd /home/konodoki/u-boot
./build-bxi-ground-station.sh
```

编译输出目录：

```text
/home/konodoki/u-boot/build/bxi-ground-station/
```

常用输出文件：

| 文件 | 用途 |
|---|---|
| `u-boot-rockchip-spi.bin` | 写入 SPI NOR 的完整 Rockchip SPI 镜像 |
| `u-boot-rockchip.bin` | 普通 Rockchip 镜像，通常用于其他启动介质或调试 |
| `idbloader.img` | DDR TPL + SPL 部分 |
| `u-boot.itb` | U-Boot FIT/ATF/TEE 部分 |
| `tee.bin` | 自动准备的 OP-TEE/BL32 镜像 |
| `u-boot-dtb.bin` | 带设备树的 U-Boot 镜像 |

### 3.2 清理后重新编译

```bash
cd /home/konodoki/u-boot
./build-bxi-ground-station.sh --clean
```

指定并行编译线程数：

```bash
./build-bxi-ground-station.sh -j8
```

### 3.3 OP-TEE 选项

默认会使用 `rkbin` 中的 BL32/OP-TEE 文件：

```bash
./build-bxi-ground-station.sh
```

不加入 TEE：

```bash
./build-bxi-ground-station.sh --no-tee
```

手动指定 TEE 文件：

```bash
./build-bxi-ground-station.sh --tee /path/to/tee.bin
```

TEE 是可选的。出现下面这类提示时，通常仍然可以生成可启动的非安全固件：

```text
Image 'simple-bin' is missing optional external blobs but is still functional: tee-os
```

### 3.4 同时生成 RKDevTool Loader

```bash
cd /home/konodoki/u-boot
./build-bxi-ground-station.sh --clean --rkdevtool-loader
```

输出：

```text
build/bxi-ground-station/rk356x_loader_v1.26.114.bin
```

该 Loader 使用 LubanCat SDK 中官方提供的：

```text
configs/rockchip-usbplug_defconfig
configs/rk3568-usbplug.config
```

脚本不会修改 USBPlug 的 `.config`、设备树、SPI 速度、SPI 总线宽度或 NAND 驱动。之前生成的 `*-usbplug-24MHz-x1*` 文件属于旧的本地修改版本，不再使用。

### 3.5 Loader 源码和预编译组件位置

本次 USBPlug 的源码和官方配置位于 LubanCat 的 U-Boot 源码树：

```text
/home/konodoki/LubanCat_SDK/u-boot/common/usbplug/usbplug.c
/home/konodoki/LubanCat_SDK/u-boot/common/usbplug/Kconfig
/home/konodoki/LubanCat_SDK/u-boot/configs/rockchip-usbplug_defconfig
/home/konodoki/LubanCat_SDK/u-boot/configs/rk3568-usbplug.config
```

该源码树的 Git 远程仓库是 `LubanCat/u-boot`。Rockchip `rkbin` 中的下列文件是预编译组件，不是本次板级 U-Boot 源码：

```text
/home/konodoki/rkbin/bin/rk35/rk3566_ddr_1056MHz_v1.26.bin
/home/konodoki/rkbin/bin/rk35/rk356x_spl_v1.14.bin
/home/konodoki/rkbin/tools/boot_merger
```

其中 DDR 初始化和部分 Rockchip 启动代码以二进制形式提供，通常不能像普通 U-Boot 源码一样直接重新编译。


该 Loader 用于 RKDevTool/rkdeveloptool 临时初始化 DDR、USB 和存储设备。它是下载到 RAM 中运行的 Loader，不等于写入 SPI NOR 的 U-Boot。

## 4. SPI NOR 镜像烧录关系

本板 SPI NOR 容量为 32 Mbit，即 4 MiB。烧录文件为：

```text
build/bxi-ground-station/u-boot-rockchip-spi.bin
```

当前布局：

```text
0x000000 - 0x007fff   保留/填充区域
0x008000              ID Block、DDR TPL、SPL
0x060000              u-boot.itb（结束地址不能超过 0x3e0000）
0x3e0000 - 0x3effff   环境变量副本 A，64 KiB
0x3f0000 - 0x3fffff   环境变量副本 B，64 KiB
```

Windows RKDevTool 写入 SPI NOR 时，使用完整的：

```text
u-boot-rockchip-spi.bin
```

不要把 `u-boot.itb` 单独当作完整 SPI 镜像烧录。

### 4.1 环境变量持久化（saveenv）

板级配置已将环境变量后端从 `ENV_IS_NOWHERE` 改为 SPI NOR。变量原本就能用
`setenv` 在内存中修改；现在执行 `saveenv` 或 `env save` 后，可以在重启、断电后恢复。

```text
CONFIG_CMD_SAVEENV=y
CONFIG_ENV_IS_IN_SPI_FLASH=y
CONFIG_ENV_REDUNDANT=y
CONFIG_ENV_SIZE=0x10000
CONFIG_ENV_SECT_SIZE=0x10000
CONFIG_ENV_OFFSET=0x3e0000
CONFIG_ENV_OFFSET_REDUND=0x3f0000
CONFIG_ENV_SPI_BUS=4
CONFIG_ENV_SPI_CS=0
CONFIG_ENV_SPI_MAX_HZ=24000000
```

两个区域各占一个独立的 64 KiB 擦除范围，共预留 128 KiB。
副本 A/B 交替使用，作用是降低更新环境变量时断电造成数据丢失的风险；
**可用环境变量容量仍约为 64 KiB（需要扣除 CRC 和状态标志），不是 128 KiB。**
SPI 总线编号 4 对应设备树的 `spi4 = &sfc`，片选为 0。

编译脚本会读取生成的 `.config`，校验两个擦除范围不重叠、不超出实际配置容量，
并禁止 SPI 固件镜像跨过 `0x3e0000`。重新编译：

```bash
cd /home/konodoki/u-boot
./build-bxi-ground-station.sh -j 4
```

将新生成的 `u-boot-rockchip-spi.bin` 重新烧录到 NOR 的起始地址 0；
**只在主机重新编译而不更新板上的 U-Boot，不会启用持久化。**
本改动不改变官方配置的 RKDevTool Loader，也不占用 eMMC 的 GPT 或文件系统空间。

环境区不作为填充内容追加进 SPI 固件文件，不需要单独烧录环境镜像。
首次启动时，若两个区域都没有有效环境，出现 `bad CRC` 或使用默认环境的提示是正常的。
初始化并测试：

```text
setenv bxi_env_test persistent-ok
saveenv
reset
```

重新进入 U-Boot 后：

```text
printenv bxi_env_test
```

应显示 `bxi_env_test=persistent-ok`。建议再做一次断电上电验证。
清理测试变量：

```text
setenv bxi_env_test
saveenv
```

恢复编译内置的默认环境并保存（会丢弃自定义启动参数等设置）：

```text
env default -a
saveenv
```

注意事项：

- `setenv` 本身只改 RAM，必须执行 `saveenv` 才会持久保存。
- 保存过程会擦写 NOR，不要把 `saveenv` 放进每次自动启动的循环。
- 普通升级时仅擦写固件占用的地址范围，可保留环境区；工具若执行“擦除所有”或整片擦除，两个副本也会丢失。
- 不要使用 `sf erase 0 0x400000` 来做保留环境的升级，也不要向环境区域随意写入其他数据。
- U-Boot 升级后，旧的持久环境会继续覆盖编译默认值；需要新默认设置时，应先备份变量，再考虑恢复默认环境。
- 如果更换不同擦除粒度的 NOR，需要确认上述 64 KiB 边界与芯片擦除粒度兼容。

## 5. 制作 eMMC 镜像前的准备

eMMC 镜像制作脚本需要一个已经准备好的 rootfs 目录，例如：

```text
/home/konodoki/rootfs/
├── bin/
├── etc/
├── lib/
├── usr/
├── var/
└── boot/
```

安装镜像制作依赖：

```bash
sudo apt install -y gdisk dosfstools e2fsprogs rsync util-linux
```

脚本会生成一个默认大小为 1800 MiB 的镜像。这个大小小于常见的 2 GB eMMC 容量，避免因厂商标称容量差异导致镜像超出设备末尾。

如果已经知道实际 eMMC 用户区容量，可以设置 `IMAGE_SIZE`，但不能超过实际容量：

```bash
IMAGE_SIZE=1800MiB
```

## 6. 制作 eMMC 镜像

### 6.1 仅复制 rootfs

```bash
cd /home/konodoki/u-boot

./make-bxi-emmc-image.sh \
    /home/konodoki/rootfs \
    build/bxi-ground-station/emmc-bxi-ground-station.img
```

### 6. 同时复制内核和设备树

```bash
cd /home/konodoki/u-boot

KERNEL_IMAGE=/path/to/Image \
DTB_IMAGE=/home/konodoki/u-boot/build/kernel-bxi-dtb/arch/arm64/boot/dts/rockchip/rk3566-lubancat-1io.dtb \
./make-bxi-emmc-image.sh \
    /home/konodoki/rootfs \
    build/bxi-ground-station/emmc-bxi-ground-station.img
```

例如：

```bash
KERNEL_IMAGE=/home/konodoki/LubanCat_SDK/kernel-6.1/arch/arm64/boot/Image \
DTB_IMAGE=/home/konodoki/u-boot/build/kernel-bxi-dtb/arch/arm64/boot/dts/rockchip/rk3566-lubancat-1io.dtb \
./make-bxi-emmc-image.sh \
    /home/konodoki/rootfs \
    build/bxi-ground-station/emmc-bxi-ground-station.img
```

脚本内部需要使用 `sudo` 挂载 loop 设备，因此建议以普通用户执行脚本，不要把整个脚本用 `sudo` 执行：

```bash
# 推荐
./make-bxi-emmc-image.sh ...

# 不推荐
sudo ./make-bxi-emmc-image.sh ...
```

生成的镜像包含：

```text
GPT
├── 分区1：FAT32，标签 BOOT，默认 256 MiB
│   ├── Image
│   ├── rk3566-lubancat-1io.dtb
│   └── extlinux/extlinux.conf
└── 分区2：ext4，标签 rootfs
    └── rootfs目录内容
```

查看镜像分区：

```bash
sgdisk --print \
    build/bxi-ground-station/emmc-bxi-ground-station.img
```

## 7. 用 Ubuntu 下的 rkdeveloptool 烧录 eMMC

设置工具、Loader 和镜像路径：

```bash
export RKDEV=/home/konodoki/rkbin/tools/rkdeveloptool
export LOADER=/home/konodoki/u-boot/build/bxi-ground-station/rk356x_loader_v1.26.114.bin
export IMAGE=/home/konodoki/u-boot/build/bxi-ground-station/emmc-bxi-ground-station.img
```

连接 OTG USB，并让板子进入 Maskrom 或 Loader 模式，然后执行：

```bash
$RKDEV ld
```

下载临时 Loader：

```bash
$RKDEV db "$LOADER"
```

再次检查设备：

```bash
$RKDEV ld
```

写入 eMMC 用户区 LBA 0：

```bash
$RKDEV wl 0x0 "$IMAGE"
```

写入完成后重启：

```bash
$RKDEV rd
```

命令作用：

```text
ld       查看 Rockchip USB 设备
 db      下载临时 Loader 到 RAM
 wl      向存储设备写数据
 rd      重启设备
```

`wl 0x0` 写入的是 eMMC 用户区，不会写入 SPI NOR，也不会写入 `mmcblk0boot0`、`mmcblk0boot1` 或 RPMB。

### 7.1 已经从 SPI NOR 启动时：可以不进 Maskrom

当前 bxi-ground-station 的主 U-Boot 已启用 RockUSB 支持：

```text
CONFIG_CMD_ROCKUSB=y
CONFIG_USB_GADGET_DOWNLOAD=y
CONFIG_USB_FUNCTION_ROCKUSB=y
```

因此，如果板子能够正常从 SPI NOR 启动进入 U-Boot，可以在 U-Boot 串口中直接执行：

```text
rockusb 0 mmc 0
```

然后在 Ubuntu 主机上执行：

```bash
$RKDEV ld
$RKDEV wl 0x0 "$IMAGE"
$RKDEV rd
```

这种方式：

```text
不需要进入 Maskrom
不需要执行 rkdeveloptool db
不需要重新下载 RKDevTool Loader
直接使用已经运行在 SPI NOR 中的 U-Boot 提供 RockUSB
```

执行 `rockusb 0 mmc 0` 后，U-Boot 会停留在 USB 下载模式，不会继续自动启动 Linux。完成烧录后用 `rkdeveloptool rd` 重启即可。

### 7.2 不能启动 SPI NOR 时：才使用 Maskrom + Loader

如果 SPI NOR 中的 U-Boot 损坏、DDR 初始化失败、USB RockUSB 没有起来，才使用：

```text
Maskrom
  ↓
rkdeveloptool db rk356x_loader_v1.26.114.bin
  ↓
rkdeveloptool wl 0x0 emmc-bxi-ground-station.img
```

这里的 Loader 只是临时下载到 RAM 中运行，并不会被集成到 SPI NOR 的 U-Boot 镜像中。

## 8. Windows RKDevTool 烧录 eMMC

如果使用 Windows RKDevTool：

1. 选择本次使用官方配置生成的 RK3566 Loader：

   ```text
   rk356x_loader_v1.26.114.bin
   ```

2. 让设备进入 Maskrom/Loader 模式；
3. 确认 RKDevTool 能发现设备；
4. 使用“下载镜像”页，而不是“升级固件”页；
5. 添加一个镜像项目：

   ```text
   名称：Image
   地址：0x00000000
   文件：emmc-bxi-ground-station.img
   ```

6. 点击下载。

不要使用下面的文件作为 eMMC 镜像：

```text
u-boot-rockchip-spi.bin
u-boot.itb
idbloader.img
```

这几个文件分别是 SPI NOR 镜像、U-Boot FIT 和启动阶段组件，不是完整的 eMMC 文件系统镜像。

本次生成的镜像已经自带 GPT，因此不需要额外选择旧的：

```text
rkbin/tools/parameter_gpt.txt
```

该文件是旧格式参数文件，并且内容针对 RK3399，不应直接用于本 RK3566 镜像。

## 9. 烧录后在 U-Boot 中检查

启动进入 U-Boot 后执行：

```text
mmc list
mmc dev 0
mmc info
part list mmc 0
```

查看 FAT32 boot 分区：

```text
fatinfo mmc 0:1
fatls mmc 0:1
```

查看 ext4 rootfs 分区：

```text
ext4ls mmc 0:2 /
```

查看 extlinux：

```text
fatls mmc 0:1 /extlinux
```

如果能看到两个分区和对应文件，说明 eMMC 的 GPT 和文件系统已经写入成功。

## 10. 手动测试启动

在 U-Boot 中：

```text
fatload mmc 0:1 0x02000000 /Image
fatload mmc 0:1 0x04000000 /rk3566-lubancat-1io.dtb
```

手动设置 rootfs 分区 UUID：

```text
setenv bootargs 'root=PARTUUID=ROOTFS_PARTUUID rootwait rw console=ttyS2,1500000n8'
booti 0x02000000 - 0x04000000
```

将 `ROOTFS_PARTUUID` 替换为镜像制作脚本输出的 rootfs PARTUUID。

如果使用 extlinux：

```text
bootflow scan
```

或者：

```text
run bootcmd
```

## 11. 常见错误

### 11.1 `mmc list` 看不到 SPI NOR

这是正常的。`mmc list` 只显示 MMC/eMMC/SD 设备。

SPI NOR 使用：

```text
sf probe
sf info
```

### 11.2 `part list mmc 0` 没有分区

说明 GPT 没有正确写入，或者写入的不是 eMMC 用户区。确认使用：

```text
rkdeveloptool wl 0x0 emmc-bxi-ground-station.img
```

不要把镜像写到 `0x60000`；`0x60000` 是 SPI NOR 中 U-Boot ITB 的地址。

### 11.3 出现 GPT 读取失败

如果针对 SPI NOR 看到 GPT 读取失败，这是正常的，因为 SPI NOR 是裸地址布局，不是 GPT 磁盘。

如果针对 eMMC 看到 GPT 读取失败，则需要确认镜像确实是脚本生成的完整 `emmc-bxi-ground-station.img`，而不是单独的 `u-boot.itb` 或 `u-boot-rockchip-spi.bin`。

### 11.4 能看到分区但不能启动

依次检查：

```text
fatinfo mmc 0:1
fatls mmc 0:1
ext4ls mmc 0:2 /
```

并确认 boot 分区至少包含：

```text
/Image
/rk3566-lubancat-1io.dtb
/extlinux/extlinux.conf
```

同时确认 `extlinux.conf` 中的 `root=PARTUUID=` 与实际 rootfs 分区 UUID 一致。

### 11.5 不要写入 RPMB

Linux 下的：

```text
/dev/mmcblk0rpmb
```

是 eMMC 安全区域，不是普通 rootfs 分区。不要将系统镜像写入该设备。
