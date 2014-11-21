#!/bin/bash

cd "`dirname "$0"`"
top="`pwd`"
stage="$top/stage"

# turn on verbose debugging output for parabuild logs.
set -x
# make errors fatal
set -e

CURL_SOURCE_DIR="curl-git"

if [ -z "$AUTOBUILD" ] ; then 
    fail
fi

if [ "$OSTYPE" = "cygwin" ] ; then
    export AUTOBUILD="`cygpath -u "$AUTOBUILD"`"
fi

# load autbuild provided shell functions and variables
set +x
eval "$("$AUTOBUILD" source_environment)"
set -x

opts=
case $AUTOBUILD_PLATFORM in
  windows)
    host="i686-win32"
  ;;
  windows64)
    host="x86_64-win"
  ;;
  darwin)
    host="universal-darwin"
  ;;
  linux)
    host="i686-linux"
    opts="-m32"
  ;;
  linux64)
    host="x86_64-linux"
    opts="-m64"
  ;;
esac

[ -n "$host" ] || fail "Unknown platform $AUTOBUILD_PLATFORM."

ZLIB_INCLUDE="${stage}"/packages/libraries/$host/include/zlib
OPENSSL_INCLUDE="${stage}"/packages/libraries/$host/include/openssl

[ -f "$ZLIB_INCLUDE"/zlib.h ] || fail "You haven't installed the zlib package yet."
[ -f "$OPENSSL_INCLUDE"/ssl.h ] || fail "You haven't installed the openssl package yet."

# The packages store their content in:
#
# "$stage"/packages/libraries/$host/include/openssl/*.h
# "$stage"/packages/libraries/$host/include/zlib/*.h
#                                           ^^^^
# "$stage"/packages/libraries/$host/lib/{debug,release}/lib*
#                                       ^^^^^^^^^^^^^^^
# That doesn't play nice with configure, therefore add symlinks
# so that configure can find the object files in
# "$stage"/packages/libraries/$host/{debug,release}/lib/lib*
# and the header files in
# "$stage"/packages/libraries/$host/{debug,release}/include

fix_package_paths()
{
    pushd "$stage/packages/libraries/$host/include"
    for zheader in zlib/*.h; do
      ln -sf $zheader
    done
    popd
    for reltype in debug release; do
      mkdir -p "$stage"/packages/libraries/$host/$reltype
      ln -sf "$stage"/packages/libraries/$host/lib/$reltype "$stage"/packages/libraries/$host/$reltype/lib
      ln -sf "$stage"/packages/libraries/$host/include      "$stage"/packages/libraries/$host/$reltype/include
    done
}

# Restore all .sos
restore_sos ()
{
    for solib in "$stage/packages/libraries/$host/lib"/{debug,release}/lib{z,ssl,crypto}.so*.disable; do
        if [ -f "$solib" ]; then
            mv -f "$solib" "${solib%.disable}"
        fi
    done
}

# Restore all .dylibs
restore_dylibs ()
{
    for dylib in "$stage/packages/libraries/$host/lib"/{debug,release}/*.dylib.disable; do
        if [ -f "$dylib" ]; then
            mv "$dylib" "${dylib%.disable}"
        fi
    done
}

# See if there's anything wrong with the checked out or
# generated files.  Main test is to confirm that c-ares
# is defeated and we're using a threaded resolver.
check_damage ()
{
    case $1 in
      windows|windows64)
            echo "Verifying Ares is disabled"
            grep 'USE_ARES\s*1' lib/config-win32.h | grep '^/\*'
        ;;

      darwin|linux|linux64)
            echo "Verifying Ares is disabled"
            egrep 'USE_THREADS_POSIX[[:space:]]+1' lib/curl_config.h
	    echo "Verifying zlib was found"
	    egrep 'HAVE_ZLIB_H[[:space:]]+1' lib/curl_config.h
	    echo "Verifying openssl was found"
	    egrep 'USE_SSLEAY[[:space:]]+1' lib/curl_config.h
	    egrep 'USE_OPENSSL[[:space:]]+1' lib/curl_config.h
	    egrep 'HAVE_OPENSSL_ENGINE_H[[:space:]]+1' lib/curl_config.h
        ;;
    esac
}

build_unix()
{
    prefix="/libraries/$host"
    reltype="$1"
    shift

    echo "LIBS = \"$LIBS\""
    [ -f ./configure ] || ./buildconf
    [ -d "$stage"/packages/libraries/$host/$reltype ] || fix_package_paths

    CFLAGS="$opts" \
        LIBS="$libs" \
	./configure --disable-ldap --disable-ldaps --enable-shared=no --disable-curldebug \
        --enable-threaded-resolver --without-libssh2 \
	--prefix="$prefix" --libdir="$prefix/lib/$reltype" \
	--with-zlib="$stage/packages$prefix/$reltype" --with-ssl="$stage/packages$prefix/$reltype" $*
    check_damage "$AUTOBUILD_PLATFORM"
    make -j 8
    make DESTDIR="$stage" install
    make distclean
}

pushd "$CURL_SOURCE_DIR"
    case $AUTOBUILD_PLATFORM in
        windows)
            check_damage "$AUTOBUILD_PLATFORM"
            packages="$(cygpath -m "$stage/packages")"
            load_vsvars
            pushd lib

                # Debug target.  DLL for SSL, static archives
                # for libcurl and zlib.  (Config created by Linden Lab)
                nmake /f Makefile.vc10 CFG=debug-ssl-dll-zlib \
                    OPENSSL_PATH="$packages/include/openssl" \
                    ZLIB_PATH="$packages/include/zlib" ZLIB_NAME="zlibd.lib" \
                    INCLUDE="$INCLUDE;$packages/include;$packages/include/zlib;$packages/include/openssl" \
                    LIB="$LIB;$packages/lib/debug" \
                    LINDEN_INCPATH="$packages/include" \
                    LINDEN_LIBPATH="$packages/lib/debug"

                # Release target.  DLL for SSL, static archives
                # for libcurl and zlib.  (Config created by Linden Lab)
                nmake /f Makefile.vc10 CFG=release-ssl-dll-zlib \
                    OPENSSL_PATH="$packages/include/openssl" \
                    ZLIB_PATH="$packages/include/zlib" ZLIB_NAME="zlib.lib" \
                    INCLUDE="$INCLUDE;$packages/include;$packages/include/zlib;$packages/include/openssl" \
                    LIB="$LIB;$packages/lib/release" \
                    LINDEN_INCPATH="$packages/include" \
                    LINDEN_LIBPATH="$packages/lib/release" 

            popd

            pushd src
                # Real unit tests aren't running on Windows yet.  But
                # we can at least build the curl command itself and
                # invoke and inspect it a bit.

                # Target can be 'debug' or 'release' but CFG's
                # are always 'release-*' for the executable build.

                nmake /f Makefile.vc10 debug CFG=release-ssl-dll-zlib \
                    OPENSSL_PATH="$packages/include/openssl" \
                    ZLIB_PATH="$packages/include/zlib" ZLIB_NAME="zlibd.lib" \
                    INCLUDE="$INCLUDE;$packages/include;$packages/include/zlib;$packages/include/openssl" \
                    LIB="$LIB;$packages/lib/debug" \
                    LINDEN_INCPATH="$packages/include" \
                    LINDEN_LIBPATH="$packages/lib/debug" 
            popd

            # conditionally run unit tests
            if [ "${DISABLE_UNIT_TESTS:-0}" = "0" ]; then
                pushd tests
                # Nothin' to do yet

                popd
            fi

            # Stage archives
            mkdir -p "${stage}"/lib/{debug,release}
            cp -a lib/debug-ssl-dll-zlib/libcurld.lib "${stage}"/lib/debug/libcurld.lib
            cp -a lib/release-ssl-dll-zlib/libcurl.lib "${stage}"/lib/release/libcurl.lib

            # Stage curl.exe and provide .dll's it needs
            mkdir -p "${stage}"/bin
            cp -af "${stage}"/packages/lib/debug/*.{dll,pdb} "${stage}"/bin/
            chmod +x-w "${stage}"/bin/*.dll   # correct package permissions
            cp -a src/curl.{exe,ilk,pdb} "${stage}"/bin/

            # Stage headers
            mkdir -p "${stage}"/include
            cp -a include/curl/ "${stage}"/include/

            # Run 'curl' as a sanity check
            echo "======================================================="
            echo "==    Verify expected versions of libraries below    =="
            echo "======================================================="
            "${stage}"/bin/curl.exe --version
            echo "======================================================="
            echo "======================================================="

            # Clean
            pushd lib
                nmake /f Makefile.vc10 clean
            popd
            pushd src
                nmake /f Makefile.vc10 clean
            popd
        ;;

        darwin)
            # Select SDK with full path.  This shouldn't have much effect on this
            # build but adding to establish a consistent pattern.
            #
            # sdk=/Developer/SDKs/MacOSX10.6.sdk/
            # sdk=/Developer/SDKs/MacOSX10.7.sdk/
            # sdk=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX10.6.sdk/
            sdk=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX10.7.sdk/
            opts="--arch i386 -iwithsysroot $sdk -mmacosx-version-min=10.6 -gdwarf-2"

            rm -rf Resources/ ../Resources tests/Resources/

            # Force libz and openssl static linkage by moving .dylibs out of the way
            trap restore_dylibs EXIT
            for dylib in "$stage"/packages/libraries/$host/lib/{debug,release}/lib{z,crypto,ssl}*.dylib; do
                if [ -f "$dylib" ]; then
                    mv "$dylib" "$dylib".disable
                fi
            done

	    libs=
	    build_unix release --disable-debug --enable-optimize
	    build_unix debug --enable-debug --disable-optimize
        ;;

        linux|linux64)
            # Force static linkage to libz and openssl by moving .sos out of the way
            trap restore_sos EXIT
            for solib in "${stage}"/packages/libraries/$host/lib/{debug,release}/lib{z,ssl,crypto}.so*; do
                if [ -f "$solib" ]; then
                    mv -f "$solib" "$solib".disable
                fi
            done

	    libs="-ldl"
	    build_unix release --disable-debug --enable-optimize
	    build_unix debug --enable-debug --disable-optimize
        ;;

        *)
	  fail "Unknown platform $AUTOBUILD_PLATFORM."
	;;
    esac
    mkdir -p "$stage/LICENSES"
    cp COPYING "$stage/LICENSES/curl.txt"
popd

mkdir -p "$stage"/docs/curl/

pass

