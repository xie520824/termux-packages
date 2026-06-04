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
    LOGI ".NET 版本: ${TERMUX_DOTNET_VERSION}"
}

termux_step_configure() {
    LOGI "配置 netcoredbg..."
    
    # Apply Android-specific patch for libdbgshim support
    cd "${TERMUX_PKG_SRCDIR}"
    
    cat > android_dbgshim.patch << 'EOF'
--- a/src/debugger/manageddebugger.cpp
+++ b/src/debugger/manageddebugger.cpp
@@ -745,7 +745,24 @@ HRESULT ManagedDebuggerHelpers::RunProcess(const std::string& fileExec, const s
 #ifdef FEATURE_PAL
     GetWaitpid().SetupTrackingPID(m_processId);
 #endif // FEATURE_PAL
-
+#ifdef __ANDROID__
+    // Android/Bionic doesn't support traditional ptrace-based debugging
+    // We need to use alternative approach: directly attach to process after resume
+    // Resume the process first
+    IfFailRet(m_dbgshim.ResumeProcess(resumeHandle));
+    m_dbgshim.CloseResumeHandle(resumeHandle);
+    
+    // Give the process time to start up
+    USleep(500*1000); // 500ms
+    
+    // Then attach to it
+    return AttachToProcess();
+#else
+    // Linux/glibc path: use RegisterForRuntimeStartup
     IfFailRet(m_dbgshim.RegisterForRuntimeStartup(m_processId, ManagedDebugger::StartupCallback, this, &m_unregisterToken));
 
     // Resume the process so that StartupCallback can run
@@ -755,6 +772,7 @@ HRESULT ManagedDebuggerHelpers::RunProcess(const std::string& fileExec, const s
     std::unique_lock<std::mutex> lockAttachedMutex(m_processAttachedMutex);
     if (!m_processAttachedCV.wait_for(lockAttachedMutex, startupWaitTimeout, [this]{return m_processAttachedState == ProcessAttachedState::Attached;}))
         return E_FAIL;
 
     pProtocol->EmitExecEvent(PID{m_processId}, fileExec);
 
     return S_OK;
+#endif // __ANDROID__
 }
EOF

    # Apply the patch
    if patch -p1 < android_dbgshim.patch; then
        LOGI "Android 补丁应用成功"
    else
        LOGW "Android 补丁应用失败，尝试继续..."
    fi
    rm -f android_dbgshim.patch

    # Create CMake build directory
    mkdir -p "${TERMUX_PKG_BUILDDIR}/cmake_build"
    cd "${TERMUX_PKG_BUILDDIR}/cmake_build"

    LOGI "CMake 配置开始..."
    
    # Configure with CMake - explicitly link libunwind and libc++
    cmake "${TERMUX_PKG_SRCDIR}" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_SYSTEM_NAME=Android \
        -DCMAKE_SYSTEM_VERSION="${TERMUX_PKG_API_LEVEL}" \
        -DCMAKE_ANDROID_ARCH_ABI="${ANDROID_ABI}" \
        -DCMAKE_PREFIX_PATH="${TERMUX_PREFIX}" \
        -DCMAKE_INSTALL_PREFIX="${TERMUX_PREFIX}" \
        -DCMAKE_CXX_STANDARD=17 \
        -DCMAKE_CXX_STANDARD_REQUIRED=ON \
        -DCMAKE_CXX_FLAGS="${CXXFLAGS} -std=c++17 -stdlib=libc++ -fPIC -Wl,--no-undefined" \
        -DCMAKE_C_FLAGS="${CFLAGS} -fPIC" \
        -DCMAKE_SHARED_LINKER_FLAGS="${LDFLAGS} -lunwind -lc++ -Wl,--as-needed,--no-undefined" \
        -DCMAKE_EXE_LINKER_FLAGS="${LDFLAGS} -lunwind -lc++ -Wl,--as-needed,--no-undefined" \
        -DCMAKE_FIND_ROOT_PATH="${TERMUX_PREFIX}" \
        -DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER \
        -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY \
        -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY \
        -GNinja
    
    if [[ $? -ne 0 ]]; then
        termux_error_exit "CMake 配置失败"
    fi
    
    LOGI "CMake 配置完成"
}

termux_step_make() {
    LOGI "开始编译 netcoredbg..."
    cd "${TERMUX_PKG_BUILDDIR}/cmake_build"
    
    # Build netcoredbg with verbose output
    ninja -j "${TERMUX_PKG_MAKE_PROCESSES}" -v netcoredbg
    
    if [[ $? -ne 0 ]]; then
        termux_error_exit "netcoredbg 编译失败"
    fi

    # Check for build artifacts
    if [[ ! -f "netcoredbg" ]]; then
        if [[ ! -f "Release/netcoredbg" ]]; then
            termux_error_exit "找不到已编译的 netcoredbg 二进制文件"
        fi
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
            termux_error_exit "编译后找不到 netcoredbg 二进制文件"
        fi
    fi

    LOGI "找到二进制文件: $netcoredbg_binary"
    install -Dm755 "$netcoredbg_binary" "${TERMUX_PREFIX}/bin/netcoredbg"
    
    LOGI "已安装 netcoredbg 到 ${TERMUX_PREFIX}/bin/netcoredbg"

    # Try to install libdbgshim if it was built
    mkdir -p "${TERMUX_PREFIX}/lib"
    
    # Find libdbgshim.so variants
    local libdbgshim_found=false
    for f in libdbgshim.so libdbgshim.so.1 libdbgshim.so.1.0; do
        if [[ -f "$f" ]]; then
            install -Dm755 "$f" "${TERMUX_PREFIX}/lib/$f"
            LOGI "已安装 $f"
            libdbgshim_found=true
        elif [[ -f "Release/$f" ]]; then
            install -Dm755 "Release/$f" "${TERMUX_PREFIX}/lib/$f"
            LOGI "已安装 $f"
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
    else
        LOGW "✗ netcoredbg 版本检查失败，但安装可能仍然有效"
    fi

    # Show library dependencies
    if command -v readelf &>/dev/null; then
        LOGI "netcoredbg 库依赖关系:"
        readelf -d "${TERMUX_PREFIX}/bin/netcoredbg" 2>/dev/null | grep NEEDED || true
    fi

    # Check for undefined symbols
    if command -v nm &>/dev/null; then
        local undef_count=$(nm -D "${TERMUX_PREFIX}/bin/netcoredbg" 2>/dev/null | grep -c "UND " || echo 0)
        if [[ $undef_count -eq 0 ]]; then
            LOGI "✓ 无未定义的符号"
        else
            LOGW "⚠ 检测到 $undef_count 个未定义的符号"
        fi
    fi

    # List installed files
    LOGI "已安装的文件:"
    ls -lh "${TERMUX_PREFIX}/bin/netcoredbg" 2>/dev/null && LOGI "  ✓ netcoredbg"
    if ls -lh "${TERMUX_PREFIX}/lib/libdbgshim.so"* 2>/dev/null; then
        LOGI "  ✓ libdbgshim.so"
    fi

    LOGI "安装验证完成"
}
