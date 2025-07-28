FROM quay.io/archlinux/archlinux:latest AS signer

ARG MOK_KEY
ARG PACKAGE_TAG="stable"
ARG GRUB_MODULES="all_video boot cat configfile echo true font gfxmenu gfxterm gzio halt iso9660 jpeg minicmd normal part_apple part_msdos part_gpt password password_pbkdf2 png reboot search search_fs_uuid search_fs_file search_label sleep test video fat loadenv loopback chain efifwsetup efinet read tpm tss2 tpm2_key_protector memdisk tar squash4 xzio blscfg linux btrfs ext2 xfs tftp http efinet luks luks2 gcry_rijndael gcry_sha1 gcry_sha256 gcry_sha512 mdraid09 mdraid1x lvm serial"
ARG GRUB_IMAGE="/boot/efi/EFI/arch-ostree/grubx64.efi"

COPY MOK.crt .

RUN <<EOC
set -euxo pipefail

cat <<EOF >> /etc/pacman.conf
[archlinux-ostree-experiments-repo]
Server = https://github.com/archlinux-ostree-experiments/pkgbuilds/releases/download/$PACKAGE_TAG
EOF

curl "https://raw.githubusercontent.com/archlinux-ostree-experiments/pkgbuilds/refs/heads/main/signing-key.asc" | GNUPGHOME=/etc/pacman.d/gnupg gpg --no-tty --import
echo -e "5\ny\n" | GNUPGHOME=/etc/pacman.d/gnupg gpg --no-tty --command-fd 0 --edit-key D4E25FFCC70A3272B7485BCC42633D74FDDC777E trust

pacman -Sy
pacman -S --noconfirm linux linux-firmware mkinitcpio lvm2 thin-provisioning-tools kbd amd-ucode intel-ucode ostree grub-blscfg sbsigntools

KERNEL_VERSION=$(basename $(find /usr/lib/modules -maxdepth 1 -mindepth 1 -type d -print0))

set +x
echo "${MOK_KEY}" > MOK.key
echo "Signing key written to $(pwd)/MOK.key"
set -x
stat "$(pwd)/MOK.key"

mkdir -p "$(dirname ${GRUB_IMAGE})"
grub-mkimage -k MOK.crt -o "$GRUB_IMAGE" -O x86_64-efi -s /usr/share/grub/sbat.csv --prefix= -v $GRUB_MODULES
sbsign --key MOK.key --cert MOK.crt --output "$GRUB_IMAGE" "$GRUB_IMAGE"
sbsign --key MOK.key --cert MOK.crt --output "/usr/lib/modules/${KERNEL_VERSION}/vmlinuz" "/usr/lib/modules/${KERNEL_VERSION}/vmlinuz"
rm MOK.key

cat <<EOF > /etc/mkinitcpio.conf
MODULES=()
BINARIES=()
FILES=()
HOOKS=(systemd microcode modconf kms keyboard sd-vconsole block sd-encrypt lvm2 filesystems fsck ostree)
COMPRESSION="zstd"
COMPRESSION_OPTIONS=()
MODULES_DECOMPRESS="no"
EOF

cat <<EOF > /etc/vconsole.conf
KEYMAP="us"
FONT="eurlatgr"
EOF
mkinitcpio -k "$KERNEL_VERSION" -v -g "/usr/lib/modules/${KERNEL_VERSION}/initramfs.img"
cat /boot/*-ucode.img "/usr/lib/modules/${KERNEL_VERSION}/initramfs.img" > "/usr/lib/modules/${KERNEL_VERSION}/initramfs-ucode.img"
mv -f "/usr/lib/modules/${KERNEL_VERSION}/initramfs-ucode.img" "/usr/lib/modules/${KERNEL_VERSION}/initramfs.img"
EOC

FROM quay.io/archlinux/archlinux:latest

ARG PACKAGE_TAG="stable"

LABEL containers.bootc 1

RUN <<EOC
set -euxo pipefail

cat <<EOF >> /etc/pacman.conf
[archlinux-ostree-experiments-repo]
Server = https://github.com/archlinux-ostree-experiments/pkgbuilds/releases/download/$PACKAGE_TAG
EOF

curl "https://raw.githubusercontent.com/archlinux-ostree-experiments/pkgbuilds/refs/heads/main/signing-key.asc" | GNUPGHOME=/etc/pacman.d/gnupg gpg --no-tty --import
echo -e "5\ny\n" | GNUPGHOME=/etc/pacman.d/gnupg gpg --no-tty --command-fd 0 --edit-key D4E25FFCC70A3272B7485BCC42633D74FDDC777E trust

# Make sure locales and man pages are not ignored and install basic packages
sed -i 's/NoExtract /# NoExtract /g' /etc/pacman.conf
pacman -Sy
pacman -S --noconfirm linux-firmware glibc glibc-locales efibootmgr ostree composefs btrfs-progs xfsprogs e2fsprogs dosfstools podman buildah skopeo bootc-git bootupd-arch-git shim-fedora grub-blscfg grub-blscfg-signed mokutil


# Setup bootupd
mkdir -p /usr/lib/bootupd/updates
mkdir -p /usr/lib/ostree-boot/efi
cp -Rv /boot/efi/EFI /usr/lib/ostree-boot/efi
/usr/libexec/bootupd generate-update-metadata

# Setup pacman
rm -f /var/lib/pacman/sync/*.db
mv /var/lib/pacman /usr/lib/pacman
sed -i 's@#DBPath.*/var/lib/pacman@DBPath = /usr/lib/pacman@g' /etc/pacman.conf

# Cleanup
rm -rf /boot/*
rm -rf /var/*
rm -rf /usr/lib/modules
mkdir -p /sysroot/ostree
ln -sfv sysroot/ostree /ostree
EOC

COPY --from=signer /usr/lib/modules /usr/lib/modules
COPY tmpfiles.d-var.conf /usr/lib/tmpfiles.d/bootc-integration.conf
COPY prepare-root.conf /usr/lib/ostree/prepare-root.conf

RUN bootc container lint
