#!/bin/bash

# Install spreads dependencies
apt-get -y install build-essential cython libffi-dev libjpeg8-dev \
		liblua5.1-0 libudev-dev libusb-1.0-0-dev libusb-dev nginx \
		python2.7-dev python-pyexiv2 python-netifaces python-pip \
		python-yaml unzip git || exit 1

# Remove gphoto, it tries to grab the usb devices
apt-get -y remove libgphoto2*
apt-get -y autoremove

# install i386 chdkptp
tar xzf $DELIVERY_DIR/files/i386.usr.local.tar.gz -C / || exit 1

# Get newest pip version
pip install --upgrade pip || exit 1
mv /usr/bin/pip /usr/bin/pip.old
ln -s /usr/local/bin/pip /usr/bin/pip
pip --version || exit 1

# Install CFFI
pip install cffi || exit 1

# Install spreads from GitHub
git clone https://github.com/jbaiter/spreads.git /usr/src/spreads || exit 1
cd /usr/src/spreads || exit 1
# https://github.com/openxc/openxc-python/issues/18
pip install --pre pyusb || exit 1
pip install -e .[web] || exit 1
python setup.py install || exit 1

# Install cython-hidapi from GitHub
pip install git+https://github.com/gbishop/cython-hidapi.git || exit 1

# Create spreads configuration directoy
mkdir -p /etc/skel/.config/spreads || exit 1
cp $DELIVERY_DIR/files/config.yaml /etc/skel/.config/spreads || exit 1

mkdir -p /var/log/spreads || exit 1
chmod a+rw /var/log/spreads || exit 1

# Install nginx configuration
cp $DELIVERY_DIR/files/nginx_default /etc/nginx/sites-enabled/default || exit 1
chmod a+x /etc/nginx/sites-enabled/default || exit 1

# Add nginx init script to default boot sequence
update-rc.d nginx defaults || exit 1
