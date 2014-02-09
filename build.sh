#!/bin/bash

if [ ${EUID} -ne 0 ]; then
  echo "This tool must be run as root! ;3"
  exit 1
fi

# =================== #
#    CONFIGURATION    #
# =================== #
BASE_DIR="$(dirname $0)"
SCRIPT_DIR="$(readlink -m $BASE_DIR)"
DELIVERY_DIR="${SCRIPT_DIR}/delivery"

# When true, script will drop into a chroot shell at the end to inspect
# the bootstrapped system
if [ -z "$DEBUG" ]; then
    DEBUG=false
fi
# Try to get version string from Git
VERSION="$(git tag -l --contains HEAD)"
if [ -z "$RELEASE" ]; then
    # We append the date, since otherwise our loopback devices will be
    # broken on multiple runs if we use the same image name each time.
    VERSION="git@$(git log --pretty=format:'%h' -n 1)_$(date +%s)"
fi
# Make sure we have a version string, if not use the current date
if [ -z "$VERSION" ]; then
    VERSION="$(date +%s)"
fi
# Do we have an iso to mogrify?
if [ -z "$1" ] && [ ! -e 'ubuntu-13.10-desktop-i386.iso' ]; then
	echo "You didn't supply an iso to modify!"
	echo "Usage: $0 /path/to/ubuntu-...-desktop-i386.iso"
	echo "Sleeping for 5, then downloading"
	echo "http://releases.ubuntu.com/saucy/ubuntu-13.10-desktop-i386.iso"
	echo "into the working directory. Hit Ctrl+C to cancel!"
	sleep 5
	wget --continue http://releases.ubuntu.com/saucy/ubuntu-13.10-desktop-i386.iso
	ISO="$(pwd)"'/ubuntu-13.10-desktop-i386.iso'
else
	ISO="$1"
fi

# -------------------------------------------------------------------- #

LOG="${SCRIPT_DIR}/build_${VERSION}.log"
IMG="${SCRIPT_DIR}/spreadlive_${VERSION}.iso"

# Path to build directory, by default a temporary directory
echo "Creating temporary directory..."
BUILD_ENV=$(mktemp -d) || exit 1
echo "Temporary directory created at $BUILD_ENV"
ISOMNT="${BUILD_ENV}/isomnt"
ISOFS="${BUILD_ENV}/isofs"
ROOTFS="${BUILD_ENV}/rootfs"

# Install dependencies
for dep in squashfs-tools genisoimage; do
  echo "Checking for $dep: $problem" | tee --append "$LOG"
  problem=$(dpkg -s $dep|grep installed) || exit 1
  if [ "" == "$problem" ]; then
    echo "No $dep. Setting up $dep" | tee --append "$LOG"
    apt-get --force-yes --yes install "$dep" &>> "$LOG" || exit 1
  fi
done

echo "Creating log file $LOG"
touch "$LOG" || exit 1

echo "Create image mount point $ISOMNT" | tee --append "$LOG"
mkdir -p "${ISOMNT}" || exit 1

echo "Create new iso staging area $ISOFS" | tee --append "$LOG"
mkdir -p "${ISOFS}" || exit 1

function unmount_all()
{
	# Unmount
	if [ ! -z ${ISOMNT} ]; then
		umount -l ${ISOMNT} &>> $LOG
	fi
	umount -l ${ROOTFS}/usr/src/delivery &>> $LOG
	umount -l ${ROOTFS}/dev/pts &>> $LOG
	umount -l ${ROOTFS}/sys &>> $LOG
	umount -l ${ROOTFS}/proc &>> $LOG
	umount -l ${ROOTFS}/dev &>> $LOG
}

function cleanup()
{
	unmount_all
	
	# Remove build directory
	if [ ! -z "$BUILD_ENV" ]; then
		echo "Remove directory $BUILD_ENV ..." | tee --append "$LOG"
		rm -rf "$BUILD_ENV"
	fi
	if [ ! -z "$1" ] && [ "$1" == "-exit" ]; then
		echo "Error occurred! Read $LOG for details" | tee --append "$LOG"
		exit 1
	fi
}

# Mount iso
echo "Loop-mounting $ISO to $ISOMNT..." | tee --append "$LOG"
mount -o loop "$ISO" "$ISOMNT" &>> "$LOG" || cleanup -exit
# Copy iso contents
echo "Copying iso filesystem to $ISOFS..." | tee --append "$LOG"
rsync --exclude=/casper/filesystem.squashfs \
		--archive "$ISOMNT/" "$ISOFS" &>> "$LOG" || cleanup -exit

# Extract squashfs root filesystem
echo "Extracting root filesystem to $ROOTFS ..." | tee --append "$LOG"
unsquashfs "$ISOMNT/casper/filesystem.squashfs" &>> "$LOG" || cleanup -exit
if [ -e "$(pwd)/squashfs-root/" ]; then
	mv "$(pwd)/squashfs-root" "$ROOTFS" &>> "$LOG" || cleanup -exit
fi

# Copy network config
echo "Copy /etc/resolv.conf ..." | tee --append "$LOG"
cp /etc/resolv.conf "${ROOTFS}/etc/" &>> "$LOG" || cleanup -exit
# Mount pseudo file systems
echo "Mounting pseudo filesystems in $ROOTFS ..." | tee --append "$LOG"
mount -o bind /dev "${ROOTFS}/dev" &>> "$LOG" || cleanup -exit
mount -t proc none "${ROOTFS}/proc" &>> "$LOG" || cleanup -exit
mount -t sysfs none "${ROOTFS}/sys" &>> "$LOG" || cleanup -exit
mount -o bind /dev/pts "${ROOTFS}/dev/pts" &>> "$LOG" || cleanup -exit
# Mount our delivery path
echo "Mounting $DELIVERY_DIR in $ROOTFS ..." | tee --append "$LOG"
mkdir -p "${ROOTFS}/usr/src/delivery" &>> "$LOG" || cleanup -exit
mount -o bind "${DELIVERY_DIR}" "${ROOTFS}/usr/src/delivery" \
		&>> "$LOG" || cleanup -exit

# Configure Hostname
echo "Writing $ROOTFS/etc/hostname ..." | tee --append "$LOG"
echo 'spreadlive' > "$ROOTFS/etc/hostname"
[ ! -e "$ROOTFS/etc/hostname" ] && cleanup -exit

# Configure Debian release and mirror
echo "Configure apt in $ROOTFS..." | tee --append "$LOG"
echo "deb http://us.archive.ubuntu.com/ubuntu/ precise universe
deb http://us.archive.ubuntu.com/ubuntu/ precise-updates universe
" >> "${ROOTFS}/etc/apt/sources.list"
# make sure the file we just wrote exists still
[ ! -e "${ROOTFS}/etc/apt/sources.list" ] && cleanup -exit

# Run user-defined scripts from DELIVERY_DIR/scripts
echo "Running custom bootstrapping scripts" | tee --append "$LOG"
for path in "$ROOTFS"/usr/src/delivery/scripts/*; do
		script=$(basename "$path")
    echo $script | tee --append "$LOG"
		DELIVERY_DIR='/usr/src/delivery' LANG=C LC_ALL=C chroot ${ROOTFS} \
				"/usr/src/delivery/scripts/$script" &>> $LOG || cleanup -exit
done

if $DEBUG; then
    echo "Dropping into shell" | tee --append "$LOG"
    LANG=C LC_ALL=C PS1="\u@CHROOT\w# " chroot ${ROOTFS} /bin/bash
fi

# Synchronize file systems
echo "Sync filesystems" | tee --append "$LOG"
sync

# Prepare filesystem for iso generation
echo "Cleaning up bootstrapped system" | tee --append "$LOG"
echo "#!/bin/bash
apt-get clean
rm -f /cleanup ~/.bash_history /etc/hosts
rm -rf /tmp/*
exit 0
" > "$ROOTFS/cleanup"
chmod +x "$ROOTFS/cleanup"
LANG=C LC_ALL=C chroot ${ROOTFS} /cleanup &>> $LOG || cleanup -exit

unmount_all

# Regen manifest
# TODO: is this necessary? the saucy doesn't have these files...
echo "Regenerating manifests..." | tee --append "$LOG"
touch "${ISOFS}/casper/filesystem.manifest"
chmod +w "${ISOFS}/casper/filesystem.manifest"
LANG=C LC_ALL=C chroot ${ROOTFS} dpkg-query -W \
   --showformat='${Package} ${Version}\n' > \
   "${ISOFS}/casper/filesystem.manifest" || cleanup -exit
cp 	"${ISOFS}/casper/filesystem.manifest" \
		"${ISOFS}/casper/filesystem.manifest-desktop" &>> $LOG || cleanup -exit
sed -i '/ubiquity/d' "${ISOFS}/casper/filesystem.manifest-desktop" || cleanup -exit
sed -i '/casper/d' "${ISOFS}/casper/filesystem.manifest-desktop" || cleanup -exit

# Make squashfs for root filesystem
echo "Squashing ${ROOTFS} into ${ISOFS}/casper/filesystem.squashfs..." \
		| tee --append "$LOG"
rm -f "${ISOFS}/casper/filesystem.squashfs"
mksquashfs "${ROOTFS}" "${ISOFS}/casper/filesystem.squashfs" &>> $LOG \
		|| cleanup -exit
# Update filesystem.size
echo "Update ${ISOFS}/casper/filesystem.size ..." | tee --append "$LOG"
printf $(du -sx --block-size=1 "${ROOTFS}" | cut -f1) > \
		"${ISOFS}/casper/filesystem.size" || cleanup -exit
[ ! -s "${ISOFS}/casper/filesystem.size" ] && cleanup -exit
# Set image name
echo "Update ${ISOFS}/README.diskdefines ..." | tee --append "$LOG"
echo '#define DISKNAME spreadlive - Ubuntu 12.04.3 LTS "Precise Pangolin" - Release i386' > "${BUILD_ENV}/README.diskdefines"
if [ -e "${ISOFS}/README.diskdefines" ]; then
	tail -n $(echo $(wc -l < "${ISOFS}/README.diskdefines")-1 | bc) \
			"${ISOFS}/README.diskdefines" >> "${BUILD_ENV}/README.diskdefines"
	OURS=$(wc -l < "${BUILD_ENV}/README.diskdefines")
	THEIRS=$(wc -l < "${ISOFS}/README.diskdefines")
	if [ $OURS -eq $THEIRS ]; then
		mv "${BUILD_ENV}/README.diskdefines" "${ISOFS}/README.diskdefines"
	fi
fi
# Recalculate md5sums
echo "Generating ${ISOFS}/md5sum.txt ..." | tee --append "$LOG"
rm -f "${ISOFS}/md5sum.txt"
find "${ISOFS}" -type f -print0  | xargs -0 md5sum | grep \
		-v isolinux/boot.cat | tee "${ISOFS}/md5sum.txt"
# ensure ${ISOFS}/md5sum.txt is not zero size
[ ! -s "${ISOFS}/md5sum.txt" ] && cleanup -exit

# Generate iso
echo "Generating ${IMG}..." | tee --append "$LOG"

# $ man genisoimage
#-b eltorito_boot_image
#			 Specifies the path and filename of the boot  image  to  be  used
#			when  making  an El Torito bootable CD for x86 PCs. The pathname
#			must be relative to the source path  specified  to  genisoimage.
#			This  option  is required to make an El Torito bootable CD.  The
#			boot image must be exactly 1200 kB, 1440  kB  or  2880  kB,  and
#			genisoimage  will use this size when creating the output ISO9660
#			filesystem.  The PC BIOS will use the image to emulate a  floppy
#			disk,  so the first 512-byte sector should contain PC boot code.
#			This will work, for example, if the boot image is  a  LILO-based
#			boot floppy.
#
#			If  the  boot image is not an image of a floppy, you need to add
#			either -hard-disk-boot or -no-emul-boot.  If the  system  should
#			not boot off the emulated disk, use -no-boot.
#
#			If -sort has not been specified, the boot images are sorted with
#			low priority (+2) to the beginning of the medium.  If you  don't
#			like  this,  you need to specify a sort weight of 0 for the boot
#			images.
#-boot-info-table
#			 Specifies that a 56-byte table with information  of  the  CD-ROM
#			layout will be patched in at offset 8 in the boot file.  If this
#			option is given,  the  boot  file  is  modified  in  the  source
#			filesystem,  so  make a copy of this file if it cannot be easily
#			regenerated!  See the EL TORITO BOOT INFO TABLE  section  for  a
#			description of this table.
#-boot-load-size load_sectors
#			 Specifies the number of "virtual" (512-byte) sectors to load  in
#			no-emulation mode.  The default is to load the entire boot file.
#			Some BIOSes may have problems if this is not a multiple of 4.
#-c boot_catalog
#			 Specifies  the  path  and filename of the boot catalog, which is
#			required for an El Torito bootable CD. The pathname must be relâ
#			ative  to  the  source path specified to genisoimage.  This file
#			will be inserted into the output tree and  not  created  in  the
#			source  filesystem,  so  be sure the specified filename does not
#			conflict with an existing file, or it will be excluded.  Usually
#			a name like boot.catalog is chosen.
#
#			If  -sort  has  not been specified, the boot catalog sorted with
#			low priority (+1) to the beginning of the medium.  If you  don't
#			like  this,  you need to specify a sort weight of 0 for the boot
#			catalog.
#-cache-inodes
#-no-cache-inodes
#			 Enable or disable caching inode and device numbers to find  hard
#			links  to  files.  If genisoimage finds a hard link (a file with
#			multiple names), the file will also be hard-linked on the CD, so
#			the  file  contents only appear once.  This helps to save space.
#			-cache-inodes is default on  Unix-like  operating  systems,  but
#			-no-cache-inodes  is  default on some other systems such as Cygâ
#			win, because it is not safe to assume  that  inode  numbers  are
#			unique  on  those systems.  (Some versions of Cygwin create fake
#			inode numbers using a weak hashing algorithm, which may  produce
#			duplicates.)   If  two  files have the same inode number but are
#			not hard links to the same file, genisoimage -cache-inodes  will
#			not  behave  correctly.   -no-cache-inodes is safe in all situaâ
#			tions, but in that case genisoimage cannot detect hard links, so
#			the resulting CD image may be larger than necessary.
#-D     Do not use deep directory relocation, and instead just pack them
#			in the way we see them.
#			If ISO9660:1999 has not been selected, this violates the ISO9660
#			standard, but it happens to work on many systems.  Use with cauâ
#			tion.
#-J     Generate Joliet directory records in addition to regular ISO9660
#			filenames.   This  is  primarily useful when the discs are to be
#			used on Windows machines.  Joliet  filenames  are  specified  in
#			Unicode  and each path component can be up to 64 Unicode characâ
#			ters long.  Note that Joliet is not a standard â only  Microsoft
#			Windows  and  Linux  systems  can  read  Joliet extensions.  For
#			greater portability, consider using both Joliet and  Rock  Ridge
#			extensions.
#-l     Allow full 31-character filenames.  Normally the  ISO9660  fileâ
#			name  will  be in an 8.3 format which is compatible with MS-DOS,
#			even though the ISO9660 standard allows filenames of  up  to  31
#			characters.   If  you use this option, the disc may be difficult
#			to use on a MS-DOS system, but will work on most other  systems.
#			Use with caution.
#-no-emul-boot
#			 Specifies  that the boot image used to create El Torito bootable
#			CDs is a "no emulation" image. The system will load and  execute
#			this image without performing any disk emulation.
#-o filename
#			 Specify  the  output  file for the the ISO9660 filesystem image.
#			This can be a disk file, a tape  drive,  or  it  can  correspond
#			directly  to the device name of the optical disc writer.  If not
#			specified, stdout is used.  Note that the output can also  be  a
#			block  device  for  a  regular disk partition, in which case the
#			ISO9660 filesystem can be mounted normally to verify that it was
#			generated correctly.
#-R     Generate  SUSP  and  RR records using the Rock Ridge protocol to
#			further describe the files on the ISO9660 filesystem.
#-r     This is like the -R option, but file ownership and modes are set
#			to more useful values.  The uid and gid are set to zero, because
#			they are usually only useful on the  author's  system,  and  not
#			useful  to  the client.  All the file read bits are set true, so
#			that files and directories are globally readable on the  client.
#			If  any  execute  bit  is set for a file, set all of the execute
#			bits, so that executables are globally executable on the client.
#			If  any search bit is set for a directory, set all of the search
#			bits, so that directories are globally searchable on the client.
#			All  write  bits  are  cleared,  because  the filesystem will be
#			mounted read-only in any case.  If any of the special mode  bits
#			are  set,  clear  them,  because  file locks are not useful on a
#			read-only filesystem, and set-id bits are not desirable for  uid
#			0  or  gid 0.  When used on Win32, the execute bit is set on all
#			files. This is a result of the lack of file permissions on Win32
#			and  the  Cygwin  POSIX  emulation  layer.  See also -uid, -gid,
#			-dir-mode, -file-mode and -new-dir-mode.
#-V volid
#			Specifies the volume ID (volume name or  label)  to  be  written
#			into  the  master  block.   There  is  space  for 32 characters.
#			Equivalent to VOLI in the .genisoimagerc file.  The volume ID is
#			used  as  the mount point by the Solaris volume manager and as a
#			label assigned to a disc on various other platforms such as Winâ
#			dows and Apple Mac OS.

genisoimage -b "isolinux/isolinux.bin" -boot-info-table \
  -boot-load-size 4 -c "isolinux/boot.cat" -cache-inodes -D \
  -J -l -no-emul-boot -o "${IMG}" -r -V 'spreadlive'  \
  "${ISOFS}" &>> $LOG || cleanup -exit

cleanup

echo "Successfully created image ${IMG}" | tee --append "$LOG"
exit 0
