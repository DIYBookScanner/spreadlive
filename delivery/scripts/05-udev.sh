#!/bin/bash

# Setup udev rules
echo 'ACTION=="add", SUBSYSTEM=="usb", MODE:="666"' > /etc/udev/rules.d/99-usb.rules || exit 1
