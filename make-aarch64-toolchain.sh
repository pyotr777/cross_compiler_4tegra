#!/bin/bash

set -e

BUILD_TOP=`pwd`
NCPUS=`getconf _NPROCESSORS_ONLN`

die() {
	echo $@ >&2
	exit 1
}

edo() {
	echo $@
	"$@" || die "$@ failed"
}

get_src() {
	# Get all the component sources
	edo wget http://ftpmirror.gnu.org/binutils/binutils-2.24.tar.gz
	edo wget http://ftpmirror.gnu.org/gcc/gcc-4.8.5/gcc-4.8.5.tar.gz
	edo wget http://ftpmirror.gnu.org/glibc/glibc-2.17.tar.xz
	edo wget --no-check-certificate https://www.kernel.org/pub/linux/kernel/v3.x/linux-3.7.10.tar.xz
	edo wget http://ftpmirror.gnu.org/mpfr/mpfr-3.1.1.tar.xz
	edo wget http://ftpmirror.gnu.org/gmp/gmp-5.0.5.tar.xz
	edo wget http://ftpmirror.gnu.org/mpc/mpc-1.0.1.tar.gz
	for f in *.tar*; do edo tar xf $f; done
}

apply_patches() {
	# Apply patches and set up support libraries
	edo pushd binutils-2.24
	for f in $BUILD_TOP/patches/binutils-2.24/*; do edo patch -p1 < $f; done
	edo popd 

	edo pushd gcc-4.8.5
	edo ln -s $BUILD_TOP/gmp-5.0.5 gmp
	edo ln -s $BUILD_TOP/mpfr-3.1.1 mpfr
	edo ln -s $BUILD_TOP/mpc-1.0.1 mpc
	for f in $BUILD_TOP/patches/gcc-4.8.5/*; do edo patch -p1 < $f; done
	edo popd
}

set_env() {
	# Set up envrionment variables
	INSTALL_PATH=$BUILD_TOP/install
	TRIPLET=aarch64-unknown-linux-gnu
	SYSROOT=$INSTALL_PATH/$TRIPLET/sysroot
	PATH=$INSTALL_PATH/bin:$PATH
}

build_binutils() {
	# Build binutils
	edo mkdir build-binutils
	edo pushd build-binutils/
	edo $BUILD_TOP/binutils-2.24/configure \
		--prefix=$INSTALL_PATH \
		--target=$TRIPLET \
		--with-sysroot=$SYSROOT \
		--disable-werror
	edo make -j${NCPUS}
	edo make install
	edo popd
}

install_linux_headers() {
	# Set up Linux headers
	edo pushd linux-3.7.10
	edo make ARCH=arm64 INSTALL_HDR_PATH=$SYSROOT/usr headers_install
	edo popd
}

build_gcc_stage1() {
	# Build 1st stage gcc
	edo mkdir build-gcc1
	edo pushd build-gcc1
	$BUILD_TOP/gcc-4.8.5/configure \
		LDFLAGS=-static \
		--prefix=$INSTALL_PATH \
		--target=$TRIPLET \
		--enable-languages=c,c++,fortran \
		--enable-theads=posix \
		--enable-shared \
		--disable-libsanitizer \
		--disable-gnu-indirect-function \
		--disable-gnu-unique-object \
		--disable-multilib \
		--with-sysroot=$SYSROOT
	edo make -j${NCPUS} all-gcc LIMITS_H_TEST=true
	edo make install-gcc
	edo popd
}

build_glibc_stage1() {
	# Build 1st stage glibc
	edo mkdir build-glibc1
	edo pushd build-glibc1
	edo mkdir -p $SYSROOT/usr/lib
	$BUILD_TOP/glibc-2.17/configure \
		--prefix=$SYSROOT/usr \
		--with-headers=$SYSROOT/usr/include \
		--build=$MACHTYPE \
		--host=$TRIPLET \
		--target=$TRIPLET \
		--enable-add-ons=nptl,$BUILD_TOP/glibc-2.17/ports \
		--with-tls \
		--disable-nscd \
		--disable-stackguard-randomization \
		CC=$TRIPLET-gcc \
		libc_cv_forced_unwind=yes
	edo make install-bootstrap-headers=yes install-headers
	edo make -j${NCPUS} csu/subdir_lib
	edo install csu/crt1.o csu/crti.o csu/crtn.o $SYSROOT/usr/lib
	edo $TRIPLET-gcc -nostdlib -nostartfiles -shared -x c /dev/null -o $SYSROOT/usr/lib/libc.so
	edo touch $SYSROOT/usr/include/gnu/stubs.h
	edo popd
}

build_gcc_support_lib() {
	# Build compiler support library
	edo mkdir build-gcc2
	edo pushd build-gcc2
	$BUILD_TOP/gcc-4.8.5/configure \
		LDFLAGS=-static \
		--prefix=$INSTALL_PATH \
		--target=$TRIPLET \
		--enable-languages=c,c++,fortran \
		--enable-theads=posix \
		--enable-shared \
		--disable-libsanitizer \
		--disable-gnu-indirect-function \
		--disable-gnu-unique-object \
		--disable-multilib \
		--with-sysroot=$SYSROOT
	edo make -j${NCPUS} all-target-libgcc
	edo make install-target-libgcc
	edo popd
}

build_final_glibc() {
	# Finish glibc
	edo mkdir build-glibc2
	edo pushd build-glibc2
	$BUILD_TOP/glibc-2.17/configure \
		--prefix=/usr \
		--with-headers=$SYSROOT/usr/include \
		--build=$MACHTYPE \
		--host=$TRIPLET \
		--target=$TRIPLET \
		--enable-add-ons=nptl,$BUILD_TOP/glibc-2.17/ports \
		--with-tls \
		--disable-nscd \
		--disable-stackguard-randomization \
		CC=$TRIPLET-gcc
	edo make -j${NCPUS}
	edo make install install_root=$SYSROOT
	edo popd
}

build_final_gcc() {
	# Build libstdc++
	edo mkdir build-gcc3
	edo pushd build-gcc3
	$BUILD_TOP/gcc-4.8.5/configure \
		LDFLAGS=-static \
		--prefix=$INSTALL_PATH \
		--target=$TRIPLET \
		--enable-languages=c,c++,fortran \
		--enable-theads=posix \
		--enable-shared \
		--disable-libsanitizer \
		--disable-gnu-indirect-function \
		--disable-gnu-unique-object \
		--disable-multilib \
		--with-sysroot=$SYSROOT
	edo make -j${NCPUS}
	edo make install
	edo popd
}

echo "Downloading sources"
edo get_src > get_src.log 2>&1
echo "Done"

echo "Applying patches"
edo apply_patches > apply_patches.log 2>&1
echo "Done"

echo "Set environment"
edo set_env
echo "Done"

echo "Build binutils"
edo build_binutils > build_binutils.log 2>&1
echo "Done"

echo "Install Linux headers"
edo install_linux_headers > install_linux_headers.log 2>&1
echo "Done"

echo "Build GCC stage1"
edo build_gcc_stage1 > build_gcc_stage1.log 2>&1
echo "Done"

echo "Build Glibc stage1"
edo build_glibc_stage1 > build_glibc_stage1.log 2>&1
echo "Done"

echo "Build GCC support lib"
edo build_gcc_support_lib > build_gcc_support_lib.log 2>&1
echo "Done"

echo "Build final Glibc"
edo build_final_glibc > build_final_glibc.log 2>&1
echo "Done"

echo "Build final GCC"
edo build_final_gcc > build_final_gcc.log 2>&1
echo "Done"

echo "Success!"
