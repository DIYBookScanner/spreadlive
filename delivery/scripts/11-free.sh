#!/bin/bash

# Oh boy! we're at 811M ! Can't we get smaller?
apt-get remove -y libreoffice-core
#apt-get remove -y thunderbird
#
# ...or maybe we can remove build-essentials, since we finished our
# install?
#
apt-get autoremove -y
