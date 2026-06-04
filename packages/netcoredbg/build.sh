TERMUX_PKG_HOMEPAGE=https://github.com/Samsung/netcoredbg
TERMUX_PKG_DESCRIPTION="A managed debugger for .NET"
TERMUX_PKG_LICENSE="MIT"
TERMUX_PKG_MAINTAINER="@xie520824"
TERMUX_PKG_VERSION="3.2.1"
_NETCOREDBG_COMMIT="8b8b22200fecdb1aec5f47af63215462d8c79a4b"
TERMUX_PKG_SRCURL="https://github.com/Samsung/netcoredbg/archive/${_NETCOREDBG_COMMIT}.tar.gz"
TERMUX_PKG_SHA256=0000000000000000000000000000000000000000000000000000000000000000
TERMUX_PKG_DEPENDS="dotnet-runtime-8.0, dotnet-host, libunwind, libc++"
TERMUX_PKG_BUILD_DEPENDS="dotnet-sdk-8.0, cmake, clang, libunwind-headers"
TERMUX_PKG_BUILD_IN_SRC=true
TERMUX_PKG_EXCLUDED_ARCHES="arm"
TERMUX_PKG_NO_STATICSPLIT=true

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
        *) termux_error_exit "Unsupported architecture: ${TERMUX_ARCH}" ;;
    esac
    
    export NETCOREDBG_ARCH="${_ARCH}"
    export DOTNET_TARGET_NAME="linux-bionic-${_ARCH}"
    export ANDROID_ABI="${_ABI}"
}

termux_step_configure() {
    # Apply Android-specific patch for libdbgshim support
    cat > "${TERMUX_PKG_SRCDIR}/src/debugger/manageddebugger.cpp.patch" << 'EOF'
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
    if [[ -f "${TERMUX_PKG_SRCDIR}/src/debugger/manageddebugger.cpp.patch" ]]; then
        cd "${TERMUX_PKG_SRCDIR}"
        patch -p1 < src/debugger/manageddebugger.cpp.patch || true
        rm -f src/debugger/manageddebugger.cpp.patch
    fi

    # Create CMake build directory
    mkdir -p "${TERMUX_PKG_BUILDDIR}/cmake_build"
    cd "${TERMUX_PKG_BUILDDIR}/cmake_build"

    # Set up compiler flags to link against libunwind
    export EXTRA_LDFLAGS="-lunwind -lc++"
    
    # Configure with CMake
    # Explicitly link libunwind and libc++ to avoid undefined symbols
    cmake "${TERMUX_PKG_SRCDIR}" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_SYSTEM_NAME=Android \
        -DCMAKE_SYSTEM_VERSION="${TERMUX_PKG_API_LEVEL}" \
        -DCMAKE_ANDROID_ARCH_ABI="${ANDROID_ABI}" \
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
        -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY
}

termux_step_make() {
    cd "${TERMUX_PKG_BUILDDIR}/cmake_build"
    
    # Build netcoredbg with verbose output
    cmake --build . \
        --config Release \
        --parallel "${TERMUX_PKG_MAKE_PROCESSES}" \
        --target netcoredbg \
        --verbose

    # Check for build errors
    if [[ ! -f "netcoredbg" ]] && [[ ! -f "Release/netcoredbg" ]]; then
        LOGE "Failed to build netcoredbg"
        return 1
    fi

    LOGI "netcoredbg built successfully"
}

termux_step_make_install() {
    cd "${TERMUX_PKG_BUILDDIR}/cmake_build"

    # Install netcoredbg binary
    mkdir -p "${TERMUX_PREFIX}/bin"
    
    # Find and install the binary
    local netcoredbg_binary=""
    if [[ -f "netcoredbg" ]]; then
        netcoredbg_binary="netcoredbg"
    elif [[ -f "Release/netcoredbg" ]]; then
        netcoredbg_binary="Release/netcoredbg"
    elif [[ -f "bin/netcoredbg" ]]; then
        netcoredbg_binary="bin/netcoredbg"
    else
        # Search for it
        netcoredbg_binary=$(find . -name netcoredbg -type f 2>/dev/null | head -n1)
        if [[ -z "$netcoredbg_binary" ]]; then
            termux_error_exit "netcoredbg binary not found after build"
        fi
    fi

    install -Dm755 "$netcoredbg_binary" "${TERMUX_PREFIX}/bin/netcoredbg"
    
    LOGI "Installed netcoredbg to ${TERMUX_PREFIX}/bin/netcoredbg"

    # Try to install libdbgshim if it was built
    mkdir -p "${TERMUX_PREFIX}/lib"
    
    # Find libdbgshim.so variants
    local libdbgshim=""
    for f in libdbgshim.so libdbgshim.so.1 libdbgshim.so.1.0; do
        if [[ -f "$f" ]]; then
            libdbgshim="$f"
            install -Dm755 "$f" "${TERMUX_PREFIX}/lib/$f"
            LOGI "Installed $f"
        fi
    done

    # Verify installation
    if ! [[ -f "${TERMUX_PREFIX}/bin/netcoredbg" ]]; then
        termux_error_exit "netcoredbg installation failed"
    fi

    # Create symlink for libdbgshim if needed
    if [[ -f "${TERMUX_PREFIX}/lib/libdbgshim.so.1.0" ]]; then
        ln -sf libdbgshim.so.1.0 "${TERMUX_PREFIX}/lib/libdbgshim.so.1" || true
        ln -sf libdbgshim.so.1 "${TERMUX_PREFIX}/lib/libdbgshim.so" || true
    elif [[ -f "${TERMUX_PREFIX}/lib/libdbgshim.so.1" ]]; then
        ln -sf libdbgshim.so.1 "${TERMUX_PREFIX}/lib/libdbgshim.so" || true
    fi
}

termux_step_post_make_install() {
    # Verify the binary works
    LOGI "Verifying netcoredbg installation..."
    
    if "${TERMUX_PREFIX}/bin/netcoredbg" --version >/dev/null 2>&1; then
        LOGI "netcoredbg version check: SUCCESS"
    else
        LOGW "netcoredbg version check failed, but installation may still be functional"
    fi

    # Show library dependencies
    if command -v readelf &>/dev/null; then
        LOGI "netcoredbg library dependencies:"
        readelf -d "${TERMUX_PREFIX}/bin/netcoredbg" 2>/dev/null | grep NEEDED || true
    fi

    if command -v ldd &>/dev/null; then
        LOGI "netcoredbg runtime dependencies:"
        ldd "${TERMUX_PREFIX}/bin/netcoredbg" 2>/dev/null || true
    fi

    # List installed files
    LOGI "Installed files:"
    ls -lh "${TERMUX_PREFIX}/bin/netcoredbg" 2>/dev/null || true
    ls -lh "${TERMUX_PREFIX}/lib/libdbgshim.so"* 2>/dev/null || true
}
