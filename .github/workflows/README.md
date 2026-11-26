# S3 OS
Bootable S3 OS desktop (Debian base + S3 desktop + disk installer).

Build in the cloud: push this folder to GitHub, open Actions > "Build S3 OS ISO" > Run workflow,
then download the S3-OS-iso artifact (unzip it to get S3-OS.iso).

Use it: write S3-OS.iso to a USB stick (Rufus in DD mode, or balenaEtcher), boot the PC from USB
(turn Secure Boot off), and use Start > "Install S3 OS..." to install to the hard disk.

Build locally instead: sudo ./build-s3os-iso.sh on a real Debian/Ubuntu machine or VM (not WSL1).
