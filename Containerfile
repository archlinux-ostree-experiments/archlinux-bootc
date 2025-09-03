FROM quay.io/archlinux/archlinux:latest AS signer

ARG PACKAGE_TAG="stable"
ARG GRUB_MODULES="all_video boot cat configfile echo true font gfxmenu gfxterm gzio halt iso9660 jpeg minicmd normal part_apple part_msdos part_gpt password password_pbkdf2 png reboot search search_fs_uuid search_fs_file search_label sleep test video fat loadenv loopback chain efifwsetup efinet read tpm tss2 tpm2_key_protector memdisk tar squash4 xzio blscfg linux btrfs ext2 xfs tftp http efinet luks luks2 gcry_rijndael gcry_sha1 gcry_sha256 gcry_sha512 mdraid09 mdraid1x lvm serial"
ARG GRUB_PACKAGE="grub-blscfg"
ARG EFI_VENDOR="arch"

RUN --mount=type=secret,id=mokkey \
    --mount=type=bind,source=MOK.crt,target=/run/secrets/MOK.crt,ro \
    <<EOC
set -euxo pipefail

# Add the `archlinux-ostree-experiments-repo` and trust its gpg key
# We cannot use `pacman-key`, because it would create a keypair and we dont ever want to include a key in the image
cat <<EOF >> /etc/pacman.conf
[archlinux-ostree-experiments-repo]
Server = https://github.com/archlinux-ostree-experiments/pkgbuilds/releases/download/$PACKAGE_TAG
EOF
curl "https://raw.githubusercontent.com/archlinux-ostree-experiments/pkgbuilds/refs/heads/main/signing-key.asc" | GNUPGHOME=/etc/pacman.d/gnupg gpg --no-tty --import
echo -e "5\ny\n" | GNUPGHOME=/etc/pacman.d/gnupg gpg --no-tty --command-fd 0 --edit-key D4E25FFCC70A3272B7485BCC42633D74FDDC777E trust


# Install the packages we need to create a general initramfs including ostree
pacman -Sy
pacman -S --noconfirm linux linux-firmware mkinitcpio lvm2 thin-provisioning-tools kbd amd-ucode intel-ucode ostree sbsigntools openssl $GRUB_PACKAGE

KERNEL_VERSION=$(basename $(find /usr/lib/modules -maxdepth 1 -mindepth 1 -type d -print0))
GRUB_VERSION=`LC_ALL=C pacman -Qi ${GRUB_PACKAGE} | grep Version | sed 's/Version *: \(.*\)/\1/'`
GRUB_IMAGE="/usr/lib/efi/grub/${GRUB_VERSION}/EFI/${EFI_VENDOR}/grubx64.efi"

mkdir -p "$(dirname ${GRUB_IMAGE})"
grub-mkimage -k /run/secrets/MOK.crt -o "$GRUB_IMAGE" -O x86_64-efi -s /usr/share/grub/sbat.csv --prefix= $GRUB_MODULES

# Sign kernel and grub images
sbsign --key /run/secrets/mokkey --cert /run/secrets/MOK.crt --output "$GRUB_IMAGE" "$GRUB_IMAGE"
sbsign --key /run/secrets/mokkey --cert /run/secrets/MOK.crt --output "/usr/lib/modules/${KERNEL_VERSION}/vmlinuz" "/usr/lib/modules/${KERNEL_VERSION}/vmlinuz"

# Verify that kernel and grub were signed correctly
sbverify --cert /run/secrets/MOK.crt "$GRUB_IMAGE"
sbverify --cert /run/secrets/MOK.crt "/usr/lib/modules/${KERNEL_VERSION}/vmlinuz"

# Provide the certificate for the derived image
mkdir -p /usr/share/mok
cp /run/secrets/MOK.crt /usr/share/mok/MOK.crt
openssl x509 -inform pem -in /usr/share/mok/MOK.crt -outform der -out /usr/share/mok/MOK.cer

# Create a general initramfs
# mkinitcpio configuration
cat <<EOF > /etc/mkinitcpio.conf
MODULES=()
BINARIES=()
FILES=()
HOOKS=(systemd microcode modconf kms keyboard sd-vconsole block sd-encrypt lvm2 filesystems fsck ostree)
COMPRESSION="zstd"
COMPRESSION_OPTIONS=()
MODULES_DECOMPRESS="no"
EOF

# mkinitcpio wants a vconsole.conf, so we supply one with sane defaults
cat <<EOF > /etc/vconsole.conf
KEYMAP="us"
FONT="eurlatgr"
EOF

# Call `mkinitcpio`, generate the initramfs
mkinitcpio -k "$KERNEL_VERSION" -g "/usr/lib/modules/${KERNEL_VERSION}/initramfs.img"

# Add microcode updates
cat /boot/*-ucode.img "/usr/lib/modules/${KERNEL_VERSION}/initramfs.img" > "/usr/lib/modules/${KERNEL_VERSION}/initramfs-ucode.img"
mv -f "/usr/lib/modules/${KERNEL_VERSION}/initramfs-ucode.img" "/usr/lib/modules/${KERNEL_VERSION}/initramfs.img"
EOC

FROM quay.io/archlinux/archlinux:latest

ARG PACKAGE_TAG="stable"

LABEL containers.bootc 1

COPY --from=signer /usr/lib/efi /usr/lib/efi
COPY --from=signer /usr/share/mok /usr/share/mok

RUN <<EOC
set -euxo pipefail

# Add the `archlinux-ostree-experiments-repo` and trust its gpg key
# We cannot use `pacman-key`, because it would create a keypair and we dont ever want to include a key in the image
cat <<EOF >> /etc/pacman.conf
[archlinux-ostree-experiments-repo]
Server = https://github.com/archlinux-ostree-experiments/pkgbuilds/releases/download/$PACKAGE_TAG
EOF
curl "https://raw.githubusercontent.com/archlinux-ostree-experiments/pkgbuilds/refs/heads/main/signing-key.asc" | GNUPGHOME=/etc/pacman.d/gnupg gpg --no-tty --import
echo -e "5\ny\n" | GNUPGHOME=/etc/pacman.d/gnupg gpg --no-tty --command-fd 0 --edit-key D4E25FFCC70A3272B7485BCC42633D74FDDC777E trust

# Make sure locales and man pages are not ignored and install basic packages
sed -i 's/NoExtract /# NoExtract /g' /etc/pacman.conf

# Install basic packages:
# linux: While we dont need linux as we get everything from the `signer` above, we want to have the package metadata to enable chunking
# glibc: We need to reinstall this, because it doesnt come with locales in the default image
# mokutil: While not strictly needed, it is small and can be _very_ handy in order to register our MOK cert with fedoras shim on installation
# sbsigntools: Similar to mokutil, this can be handy for debugging purposes (sbverify) or could be used to craft signatures with a custom owner key
# The filesystem tools are needed during bootcs OS installation in order to create the filesystems on the target disk
pacman -Sy
pacman -S --noconfirm linux linux-firmware \
    glibc glibc-locales \
    efibootmgr mokutil sbsigntools shim-fedora grub-blscfg \
    ostree bootc-git bootupd-git \
    composefs btrfs-progs xfsprogs e2fsprogs dosfstools \
    podman buildah skopeo

# Generate bootupd metadata
find /usr/lib/efi
/usr/libexec/bootupd -v generate-update-metadata

# Uncomment the following line to save some space and delete remote databases
# rm -f /var/lib/pacman/sync/*.db
# It currently seems to use about 8 MiB, which I personally consider worthwhile for debugging purposes.
# Moreover, it allows remote package search which can be handy from time to time, even if no packages can be installed on an immutable system.

# Setup pacman such that users can search the database on their immutable system
# Note: bootupd uses package data so this snippet has to come after bootupd metadata generation
mv /var/lib/pacman /usr/lib/pacman
sed -i 's@#DBPath.*/var/lib/pacman@DBPath = /usr/lib/pacman@g' /etc/pacman.conf

# Cleanup
# /var is meant to be writable by users, we dont want to mess with that
# Required directories can be created by tmpfiles.d on boot
rm -rf /var/*
# Boot is populated by bootupd
rm -rf /boot/*
# We will copy /usr/lib/modules from the signer above later, including the initramfs and the signed kernel image
rm -rf /usr/lib/modules

# Ensure OSTree-compatible directory structure
# Create directories and symlinks
mkdir -p /sysroot/ostree
ln -sfv sysroot/ostree /ostree

# Print /etc/group and /etc/passwd for debugging purposes
cat /etc/passwd
cat /etc/group

# List all files that are not owned by uid/gid root
find /usr /etc \( ! -user root -o ! -group root \) -ls

# Finally, list all users, groups that are managed by systemd
systemd-analyze --no-pager cat-config sysusers.d

# Lets hope to get a good idea how likely uid/gid drift is going to occur
EOC

COPY --from=signer /usr/lib/modules /usr/lib/modules
COPY tmpfiles.d-var.conf /usr/lib/tmpfiles.d/bootc-integration.conf
COPY prepare-root.conf /usr/lib/ostree/prepare-root.conf

RUN bootc container lint
