::

                                  _ _    _
     ___ _ __  _ __ ___  __ _  __| | |  (_)_   __ __
    / __| '_ \| '__/ _ \/ _` |/ _` | '  | | \ / / _ \
    \__ \ |_) | | |  __/ (_| | (_| | |__| |\ ' |  __/
    |___/ .__/|_|  \___|\__,_|\__,_|____|_| \_/ \___|
        |_|                        


Ubuntu LiveCD image tailored for running a DIYBookScanner with the spreads
software suite.

Requirements
============
* `git`

Usage
=====
To generate an image, run the `build.sh` script as root:

::

    $ sudo ./build.sh

The image will generate an Ubuntu LiveCD image with up-to-date packages and 
spreads with the currently experimental webinterface pre-installed and 
pre-configured (for use with Canon A2200 cameras running CHDK). Spreads will be 
automatically launched on startup. Make sure that your devices are turned on 
before the boot has finished.
