TERMUX_PKG_HOMEPAGE=https://github.com/Samsung/netcoredbg
TERMUX_PKG_DESCRIPTION="A managed debugger for .NET"
TERMUX_PKG_LICENSE="MIT"
TERMUX_PKG_MAINTAINER="@xie520824"
TERMUX_PKG_VERSION="3.2.0"
_NETCOREDBG_COMMIT="8b8b22200fecdb1aec5f47af63215462d8c79a4b"
TERMUX_PKG_SRCURL="https://github.com/Samsung/netcoredbg/archive/${_NETCOREDBG_COMMIT}.tar.gz"
TERMUX_PKG_SHA256=0000000000000000000000000000000000000000000000000000000000000000  # Will be updated
TERMUX_PKG_DEPENDS="dotnet-runtime-8.0, dotnet-host, libunwind"
TERMUX_PKG_BUILD_DEPENDS="dotnet-sdk-8.0, cmake, clang"
TERMUX_PKG_BUILD_IN_SRC=true
TERMUX_PKG_EXCLUDED_ARCHES="arm"
TERMUX_PKG_BREAKS="netcoredbg-old"
TERMUX_PKG_REPLACES="netcoredbg-old"

termux_step_pre_configure() {
    # Setup .NET environment for building
    termux_setup_dotnet

    # Set up build environment
    export DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1
    export DOTNET_CLI_TELEMETRY_OPTOUT=1
    
    # Get architecture mapping
    case "${TERMUX_ARCH}" in
        aarch64) _ARCH="arm64" ;;
        arm) _ARCH="arm" ;;
        i686) _ARCH="x86" ;;
        x86_64) _ARCH="x64" ;;
        *) termux_error_exit "Unsupported architecture: ${TERMUX_ARCH}" ;;
    esac
    export NETCOREDBG_ARCH="${_ARCH}"
    export DOTNET_TARGET_NAME="linux-bionic-${_ARCH}"
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

    # Configure with CMake
    cmake "${TERMUX_PKG_SRCDIR}" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_SYSTEM_NAME=Android \
        -DCMAKE_SYSTEM_VERSION="${TERMUX_PKG_API_LEVEL}" \
        -DCMAKE_ANDROID_ARCH_ABI="arm64-v8a" \
        -DCMAKE_ANDROID_NDK="${TERMUX_STANDALONE_TOOLCHAIN}/.." \
        -DCMAKE_PREFIX_PATH="${TERMUX_PREFIX}" \
        -DCMAKE_INSTALL_PREFIX="${TERMUX_PREFIX}" \
        -DCMAKE_CXX_FLAGS="${CXXFLAGS} -std=c++17" \
        -DCMAKE_C_FLAGS="${CFLAGS}" \
        -DCMAKE_LD_FLAGS="${LDFLAGS}" \
        -DCMAKE_FIND_ROOT_PATH="${TERMUX_PREFIX}" \
        -DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER \
        -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY \
        -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY
}

termux_step_make() {
    cd "${TERMUX_PKG_BUILDDIR}/cmake_build"
    
    # Build netcoredbg
    cmake --build . \
        --config Release \
        --parallel "${TERMUX_PKG_MAKE_PROCESSES}" \
        --target netcoredbg

    # Build supporting libraries if available
    if cmake --build . --config Release --parallel "${TERMUX_PKG_MAKE_PROCESSES}" --target dbgshim 2>/dev/null; then
        LOGI "dbgshim built successfully"
    fi
}

termux_step_make_install() {
    cd "${TERMUX_PKG_BUILDDIR}/cmake_build"

    # Install netcoredbg binary
    mkdir -p "${TERMUX_PREFIX}/bin"
    if [[ -f "netcoredbg" ]]; then
        install -Dm755 netcoredbg "${TERMUX_PREFIX}/bin/netcoredbg"
    elif [[ -f "Release/netcoredbg" ]]; then
        install -Dm755 Release/netcoredbg "${TERMUX_PREFIX}/bin/netcoredbg"
    else
        termux_error_exit "netcoredbg binary not found after build"
    fi

    # Install libraries if built
    mkdir -p "${TERMUX_PREFIX}/lib"
    
    if [[ -f "libdbgshim.so" ]]; then
        install -Dm755 libdbgshim.so "${TERMUX_PREFIX}/lib/libdbgshim.so"
    elif [[ -f "Release/libdbgshim.so" ]]; then
        install -Dm755 Release/libdbgshim.so "${TERMUX_PREFIX}/lib/libdbgshim.so"
    fi

    if [[ -f "libdbgshim.so.1" ]]; then
        install -Dm755 libdbgshim.so.1 "${TERMUX_PREFIX}/lib/libdbgshim.so.1"
    fi

    # Verify installation
    if ! [[ -f "${TERMUX_PREFIX}/bin/netcoredbg" ]]; then
        termux_error_exit "netcoredbg installation failed"
    fi

    # Create symlink if needed
    if [[ -f "${TERMUX_PREFIX}/lib/libdbgshim.so" ]]; then
        ln -sf libdbgshim.so "${TERMUX_PREFIX}/lib/libdbgshim.so.1" || true
    fi
}

termux_step_post_make_install() {
    # Verify the binary works
    "${TERMUX_PREFIX}/bin/netcoredbg" --version || LOGW "netcoredbg version check failed, but installation may still be OK"

    # Show library dependencies
    if command -v ldd &>/dev/null; then
        LOGI "netcoredbg dependencies:"
        ldd "${TERMUX_PREFIX}/bin/netcoredbg" || true
    fi
}
