#!/bin/bash
set -e
#export PKG_ARCH=${PKG_ARCH-iphoneos-arm}
export PKG_ARCH=iphoneos-arm
export PATH=~/toolchain4/telesphoreo/pre/bin:$PATH 
#~/toolchain4/telesphoreo/exec.sh com.saurik.winterboard make "$@"
~/toolchain4/telesphoreo/exec.sh veency make "$@"
export CODESIGN_ALLOCATE=$(which arm-apple-darwin9-codesign_allocate)
~/toolchain4/telesphoreo/util/ldid -S *.dylib
make package -B
