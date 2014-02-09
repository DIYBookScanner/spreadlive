#!/bin/bash

# set up /etc/skel/
tar xzf $DELIVERY_DIR/files/etc.skel.tar.gz -C / || exit 1
