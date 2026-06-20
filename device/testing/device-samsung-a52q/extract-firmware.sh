#!/bin/sh -eu

sudo mkdir -p /mnt/extract-firmware/apnhlos
sudo mount /dev/disk/by-partlabel/apnhlos /mnt/extract-firmware/apnhlos

for firmware_type in a615_zap adsp cdsp ipa_fws venus; do
	sudo pil-squasher "/usr/lib/firmware/qcom/sm7125/a52q/${firmware_type}.mbn" "/mnt/extract-firmware/apnhlos/image/${firmware_type}.mdt"
done

sudo umount /mnt/extract-firmware/apnhlos
sudo rmdir /mnt/extract-firmware/apnhlos
