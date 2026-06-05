TERMUX_PKG_HOMEPAGE=https://github.com/Samsung/netcoredbg
TERMUX_PKG_DESCRIPTION="A managed debugger for .NET"
TERMUX_PKG_LICENSE="MIT"
TERMUX_PKG_MAINTAINER="@xie520824"
TERMUX_PKG_VERSION="3.1.3-1062"
_NETCOREDBG_COMMIT="8b8b22200fecdb1aec5f47af63215462d8c79a4b"
TERMUX_PKG_SRCURL="https://github.com/Samsung/netcoredbg/archive/${_NETCOREDBG_COMMIT}.tar.gz"
TERMUX_PKG_SHA256=4138f6f99432822b7f56053b91abb550607e1015d91275b82c3cddeaa02d903e
TERMUX_PKG_DEPENDS="dotnet-runtime-8.0, dotnet-host, libunwind, libc++"
TERMUX_PKG_BUILD_DEPENDS="dotnet-sdk-8.0, cmake, clang, libunwind-headers"
TERMUX_PKG_BUILD_IN_SRC=true
TERMUX_PKG_EXCLUDED_ARCHES="arm"
TERMUX_PKG_NO_STATICSPLIT=true
TERMUX_PKG_AUTO_UPDATE=false

termux_step_pre_configure() {
    # Setup .NET environment
    termux_setup_cmake
    termux_setup_dotnet

    export DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1
    export DOTNET_CLI_TELEMETRY_OPTOUT=1
    
    # Get architecture mapping
    case "${TERMUX_ARCH}" in
        aarch64) 
            _ARCH="arm64"
            _ABI="arm64-v8a"
            ;;
        arm) 
            _ARCH="arm"
            _ABI="armeabi-v7a"
            ;;
        i686) 
            _ARCH="x86"
            _ABI="x86"
            ;;
        x86_64) 
            _ARCH="x64"
            _ABI="x86_64"
            ;;
        *) termux_error_exit "不支持的架构: ${TERMUX_ARCH}" ;;
    esac
    
    export NETCOREDBG_ARCH="${_ARCH}"
    export DOTNET_TARGET_NAME="linux-bionic-${_ARCH}"
    export ANDROID_ABI="${_ABI}"
    
    LOGI "构建配置:"
    LOGI "  架构: ${TERMUX_ARCH} -> ${_ARCH}"
    LOGI "  ABI: ${_ABI}"
    LOGI "  NDK 路径: ${TERMUX_STANDALONE_TOOLCHAIN}"
    LOGI ".NET 版本: ${TERMUX_DOTNET_VERSION}"
}

termux_step_configure() {
    LOGI "配置 netcoredbg..."
    
    cd "${TERMUX_PKG_SRCDIR}"
    
    # Create CMake build directory
    mkdir -p "${TERMUX_PKG_BUILDDIR}/cmake_build"
    cd "${TERMUX_PKG_BUILDDIR}/cmake_build"
    
    LOGI "CMake 配置开始..."
    
    # Ensure CMAKE_MAKE_PROGRAM is set
    if command -v ninja &>/dev/null; then
        export CMAKE_MAKE_PROGRAM=$(which ninja)
    else
        export CMAKE_MAKE_PROGRAM=$(which make)
    fi

    # Configure with CMake using Termux toolchain
    # Use the standard Termux CMake configuration
    cmake "${TERMUX_PKG_SRCDIR}" \
        -DCMAKE_TOOLCHAIN_FILE="${TERMUX_CMAKE_TOOLCHAIN}" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_PREFIX_PATH="${TERMUX_PREFIX}" \
        -DCMAKE_INSTALL_PREFIX="${TERMUX_PREFIX}" \
        -DCMAKE_CXX_STANDARD=17 \
        -DCMAKE_CXX_STANDARD_REQUIRED=ON \
        -DCMAKE_CXX_FLAGS="${CXXFLAGS} -std=c++17 -stdlib=libc++ -fPIC" \
        -DCMAKE_C_FLAGS="${CFLAGS} -fPIC" \
        -DCMAKE_SHARED_LINKER_FLAGS="${LDFLAGS} -lunwind -lc++ -Wl,--as-needed" \
        -DCMAKE_EXE_LINKER_FLAGS="${LDFLAGS} -lunwind -lc++ -Wl,--as-needed" \
        -DCMAKE_FIND_ROOT_PATH="${TERMUX_PREFIX}" \
        -DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER \
        -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY \
        -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY \
        -DCMAKE_MAKE_PROGRAM="${CMAKE_MAKE_PROGRAM}"
    
    if [[ $? -ne 0 ]]; then
        LOGE "CMake 配置失败"
        # Try alternative configuration without toolchain file
        LOGI "尝试使用替代配置..."
        
        cmake "${TERMUX_PKG_SRCDIR}" \
            -DCMAKE_C_COMPILER="${CC}" \
            -DCMAKE_CXX_COMPILER="${CXX}" \
            -DCMAKE_AR="${AR}" \
            -DCMAKE_RANLIB="${RANLIB}" \
            -DCMAKE_STRIP="${STRIP}" \
            -DCMAKE_BUILD_TYPE=Release \
            -DCMAKE_PREFIX_PATH="${TERMUX_PREFIX}" \
            -DCMAKE_INSTALL_PREFIX="${TERMUX_PREFIX}" \
            -DCMAKE_CXX_STANDARD=17 \
            -DCMAKE_CXX_FLAGS="${CXXFLAGS} -std=c++17 -stdlib=libc++ -fPIC" \
            -DCMAKE_C_FLAGS="${CFLAGS} -fPIC" \
            -DCMAKE_SHARED_LINKER_FLAGS="${LDFLAGS} -lunwind -lc++" \
            -DCMAKE_EXE_LINKER_FLAGS="${LDFLAGS} -lunwind -lc++" \
            -DCMAKE_MAKE_PROGRAM="${CMAKE_MAKE_PROGRAM}"
        
        if [[ $? -ne 0 ]]; then
            termux_error_exit "CMake 配置失败（所有方法均失败）"
        fi
    fi
    
    LOGI "CMake 配置完成"
}

termux_step_make() {
    LOGI "开始编译 netcoredbg..."
    cd "${TERMUX_PKG_BUILDDIR}/cmake_build"
    
    # Build with make or ninja
    if command -v ninja &>/dev/null && [[ -f build.ninja ]]; then
        LOGI "使用 ninja 编译..."
        ninja -j "${TERMUX_PKG_MAKE_PROCESSES}" netcoredbg
    else
        LOGI "使用 make 编译..."
        make -j "${TERMUX_PKG_MAKE_PROCESSES}"
    fi
    
    if [[ $? -ne 0 ]]; then
        termux_error_exit "netcoredbg 编译失败"
    fi

    # Check for build artifacts
    if [[ ! -f "netcoredbg" ]] && [[ ! -f "Release/netcoredbg" ]] && [[ ! -f "bin/netcoredbg" ]]; then
        termux_error_exit "找不到已编译的 netcoredbg 二进制文件"
    fi

    LOGI "netcoredbg 编译成功"
}

termux_step_make_install() {
    LOGI "安装 netcoredbg..."
    cd "${TERMUX_PKG_BUILDDIR}/cmake_build"

    # Install netcoredbg binary
    mkdir -p "${TERMUX_PREFIX}/bin"
    
    # Find and install the binary
    local netcoredbg_binary=""
    if [[ -f "netcoredbg" ]]; then
        netcoredbg_binary="./netcoredbg"
    elif [[ -f "Release/netcoredbg" ]]; then
        netcoredbg_binary="./Release/netcoredbg"
    elif [[ -f "bin/netcoredbg" ]]; then
        netcoredbg_binary="./bin/netcoredbg"
    else
        # Search for it
        netcoredbg_binary=$(find . -maxdepth 3 -name netcoredbg -type f 2>/dev/null | head -n1)
        if [[ -z "$netcoredbg_binary" ]]; then
            # List what we have
            LOGE "二进制文件搜索结果:"
            ls -la . 2>/dev/null || true
            ls -la Release/ 2>/dev/null || true
            ls -la bin/ 2>/dev/null || true
            termux_error_exit "编译后找不到 netcoredbg 二进制文件"
        fi
    fi

    LOGI "找到二进制文件: $netcoredbg_binary"
    
    # Copy the binary
    cp "$netcoredbg_binary" "${TERMUX_PREFIX}/bin/netcoredbg"
    chmod 755 "${TERMUX_PREFIX}/bin/netcoredbg"
    
    LOGI "已安装 netcoredbg 到 ${TERMUX_PREFIX}/bin/netcoredbg"

    # Try to install libdbgshim if it was built
    mkdir -p "${TERMUX_PREFIX}/lib"
    
    # Find libdbgshim.so variants
    local libdbgshim_found=false
    for f in $(find . -maxdepth 2 -name "libdbgshim.so*" -type f 2>/dev/null); do
        if [[ -f "$f" ]]; then
            cp "$f" "${TERMUX_PREFIX}/lib/$(basename $f)"
            chmod 755 "${TERMUX_PREFIX}/lib/$(basename $f)"
            LOGI "已安装 $(basename $f)"
            libdbgshim_found=true
        fi
    done

    # Verify installation
    if ! [[ -f "${TERMUX_PREFIX}/bin/netcoredbg" ]]; then
        termux_error_exit "netcoredbg 安装失败"
    fi

    # Create symlinks for libdbgshim if needed
    if [[ "$libdbgshim_found" == "true" ]]; then
        if [[ -f "${TERMUX_PREFIX}/lib/libdbgshim.so.1.0" ]]; then
            ln -sf libdbgshim.so.1.0 "${TERMUX_PREFIX}/lib/libdbgshim.so.1" 2>/dev/null || true
            ln -sf libdbgshim.so.1 "${TERMUX_PREFIX}/lib/libdbgshim.so" 2>/dev/null || true
        elif [[ -f "${TERMUX_PREFIX}/lib/libdbgshim.so.1" ]]; then
            ln -sf libdbgshim.so.1 "${TERMUX_PREFIX}/lib/libdbgshim.so" 2>/dev/null || true
        fi
    fi

    LOGI "安装完成"
}

termux_step_post_make_install() {
    LOGI "验证安装..."
    
    # Verify the binary works
    if "${TERMUX_PREFIX}/bin/netcoredbg" --version >/dev/null 2>&1; then
        LOGI "✓ netcoredbg 版本检查: 成功"
        "${TERMUX_PREFIX}/bin/netcoredbg" --version
    else
        LOGW "✗ netcoredbg 版本检查失败，但安装可能仍然有效"
    fi

    # Show library dependencies using readelf if available
    if command -v readelf &>/dev/null; then
        LOGI "netcoredbg 库依赖关系:"
        readelf -d "${TERMUX_PREFIX}/bin/netcoredbg" 2>/dev/null | grep NEEDED | head -10
    fi

    # List installed files
    LOGI "已安装的文件:"
    if [[ -f "${TERMUX_PREFIX}/bin/netcoredbg" ]]; then
        ls -lh "${TERMUX_PREFIX}/bin/netcoredbg"
        LOGI "  ✓ netcoredbg"
    fi
    
    if ls "${TERMUX_PREFIX}/lib/libdbgshim.so"* 2>/dev/null | head -1 >/dev/null; then
        LOGI "  ✓ libdbgshim libraries"
        ls -lh "${TERMUX_PREFIX}/lib/libdbgshim.so"*
    fi

    LOGI "安装验证完成"
}
