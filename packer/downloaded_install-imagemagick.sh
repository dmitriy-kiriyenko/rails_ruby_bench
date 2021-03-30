#!/bin/bash
set -e

# version check: https://github.com/ImageMagick/ImageMagick/releases
IMAGE_MAGICK_VERSION="7.0.10-58"
IMAGE_MAGICK_HASH="0daabb64602164940fbf95cbd6f16709903eef5d3eee7bd329da878f17605df5"

# version check: https://github.com/strukturag/libheif/releases
LIBHEIF_VERSION="1.10.0"
LIBHEIF_HASH="317a44bf157ba297638ab5a258040ef6ec4895d620cd58f52195f3f89c9eea28"

# version check: https://aomedia.googlesource.com/aom
LIB_AOM_VERSION="2.0.1"

# We use debian, but GitHub CI is stuck on Ubuntu Bionic, so this must be compatible with both
LIBJPEGTURBO=$(cat /etc/issue | grep -qi Debian && echo 'libjpeg62-turbo libjpeg62-turbo-dev' || echo 'libjpeg-turbo8 libjpeg-turbo8-dev')

PREFIX=/usr/local
WDIR=/tmp/imagemagick

# Install build deps
apt -y -q remove imagemagick
apt -y -q install git make gcc pkg-config autoconf curl g++ \
    yasm cmake \
    libde265-0 libde265-dev ${LIBJPEGTURBO} x265 libx265-dev libtool \
    libpng16-16 libpng-dev ${LIBJPEGTURBO} libwebp6 libwebp-dev libgomp1 libwebpmux3 libwebpdemux2 ghostscript libxml2-dev libxml2-utils \
    libbz2-dev gsfonts libtiff-dev libfreetype6-dev libjpeg-dev

mkdir -p $WDIR
cd $WDIR

# Building libaom
git clone https://aomedia.googlesource.com/aom
cd aom && git checkout v${LIB_AOM_VERSION} && cd ..
mkdir build_aom
cd build_aom
cmake ../aom/ -DENABLE_TESTS=0 -DBUILD_SHARED_LIBS=1 && make && make install
ldconfig /usr/local/lib
cd ..
rm -rf aom
rm -rf build_aom

# Build and install libheif
cd $WDIR
wget -O $WDIR/libheif.tar.gz "https://github.com/strukturag/libheif/archive/v$LIBHEIF_VERSION.tar.gz"
sha256sum $WDIR/libheif.tar.gz
echo "$LIBHEIF_HASH $WDIR/libheif.tar.gz" | sha256sum -c
tar -xzvf $WDIR/libheif.tar.gz
cd libheif-$LIBHEIF_VERSION
./autogen.sh
./configure
make && make install

# Build and install ImageMagick
wget -O $WDIR/ImageMagick.tar.gz "https://github.com/ImageMagick/ImageMagick/archive/$IMAGE_MAGICK_VERSION.tar.gz"
sha256sum $WDIR/ImageMagick.tar.gz
echo "$IMAGE_MAGICK_HASH $WDIR/ImageMagick.tar.gz" | sha256sum -c
IMDIR=$WDIR/$(tar tzf $WDIR/ImageMagick.tar.gz --wildcards "ImageMagick-*/configure" |cut -d/ -f1)
tar zxf $WDIR/ImageMagick.tar.gz -C $WDIR
cd $IMDIR
PKG_CONF_LIBDIR=$PREFIX/lib LDFLAGS=-L$PREFIX/lib CFLAGS=-I$PREFIX/include ./configure \
          --prefix=$PREFIX \
          --enable-static \
          --enable-bounds-checking \
          --enable-hdri \
          --enable-hugepages \
          --with-threads \
          --with-modules \
          --with-quantum-depth=16 \
          --without-magick-plus-plus \
          --with-bzlib \
          --with-zlib \
          --without-autotrace \
          --with-freetype \
          --with-jpeg \
          --without-lcms \
          --with-lzma \
          --with-png \
          --with-tiff \
          --with-heic \
          --with-webp
make all && make install

cd $HOME
rm -rf $WDIR
ldconfig /usr/local/lib
