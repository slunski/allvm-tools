enable_language(ASM)

set(MUSL musl-1.1.20)

set(MUSL_DIR "${PROJECT_SOURCE_DIR}/third_party/musl")
set(MUSL_TARBALL "${MUSL_DIR}/${MUSL}.tar.gz")

set(MUSL_PATCHES
  ## # ${MUSL_DIR}/patches/0002-Disable-vdso-support-on-x86_64-we-don-t-support-it-y.patch
  ## ${MUSL_DIR}/patches/0003-Remove-simple-malloc-gets-in-way-of-real-malloc.patch
  ## #  ${MUSL_DIR}/patches/0004-KLUDGE-More-workaround-weak-alias-this-time-tackling.patch
  ${MUSL_DIR}/patches/0005-Another-weak_alias-victim-destructors-for-stdio-and-.patch
  ## ${MUSL_DIR}/patches/0006-configure-improve-tryflag-to-reject-ignored-opt-argu.patch
  ## ${MUSL_DIR}/patches/0007-Partially-revert-remove-potentially-PIC-incompatible.patch
  ## ${MUSL_DIR}/patches/0008-kludge-around-_DYNAMIC-and-our-bad-weak-symbol-handl.patch
  ${MUSL_DIR}/patches/0009-configure-don-t-force-disable-unwind-tables-let-TC-d.patch
  ${MUSL_DIR}/patches/0010-configure-don-t-add-fomit-frame-pointer.patch

  # Upstream commits
  ${MUSL_DIR}/patches/upstream/0001-implement-fexecve-in-terms-of-execveat-when-it-exist.patch
  ${MUSL_DIR}/patches/upstream/0002-fix-mistake-cruft-in-1.1.20-release-notes.patch
  ${MUSL_DIR}/patches/upstream/0003-in-pthread_mutex_trylock-EBUSY-out-more-directly-whe.patch
  ${MUSL_DIR}/patches/upstream/0004-in-pthread_mutex_timedlock-avoid-repeatedly-reading-.patch
  ${MUSL_DIR}/patches/upstream/0005-fix-namespace-violation-for-c11-mutex-functions.patch
  # Additional upstream, non-consecutive
  ${MUSL_DIR}/patches/upstream/fix-file-locking-race.patch
  ${MUSL_DIR}/patches/upstream/name_to_handle_at-001.patch
  ${MUSL_DIR}/patches/upstream/name_to_handle_at-002.patch
  ${MUSL_DIR}/patches/upstream/rework-posix_spawnp.patch
  ${MUSL_DIR}/patches/upstream/tty-more-precise-errors.patch
  ${MUSL_DIR}/patches/upstream/fix-getaddrinfo.patch
  ${MUSL_DIR}/patches/upstream/increase-default-thread-stack-guard-size.patch 
)

set(MUSL_CFLAGS_EXTRA "")
if ("${CMAKE_CXX_COMPILER_ID}" STREQUAL "Clang")
  # Bug in LLVM 7.0 causes compiler to crash!
  if (CMAKE_CXX_COMPILER_VERSION VERSION_LESS 7.0)
    list(APPEND MUSL_PATCHES
      ${MUSL_DIR}/patches/0001-Build-with-fPIC-large-code-model-to-workaround-RTDyL.patch
    )
  endif()
  # Don't complain about 'unused' arguments
  # This happens when building assembly files using same CFLAGS used for C files,
  # lots of them don't make any sense for assembly code so they go unused.
  set(MUSL_CFLAGS_EXTRA "-Qunused-arguments")
  # Disable other warnings that are stylistic than actual problems
  set(MUSL_CFLAGS_EXTRA "${MUSL_CFLAGS_EXTRA} -Wno-parentheses -Wno-tautological-compare")
  set(MUSL_CFLAGS_EXTRA "${MUSL_CFLAGS_EXTRA} -Wno-string-plus-int")
  # Further disable warnings about unsupported attrs/pragmas, in theory musl supports clang.
  set(MUSL_CFLAGS_EXTRA "${MUSL_CFLAGS_EXTRA} -Wno-ignored-attributes -Wno-unknown-pragmas")
endif()

set(MUSL_CFLAGS_EXTRA "${MUSL_CFLAGS_EXTRA} -fstack-protector-all")

set(MUSL_CFLAGS "-fPIC ${MUSL_CFLAGS_EXTRA}" CACHE string "CFLAGS for building musl")

set(MUSL_PATCH_COMMANDS COMMAND echo "Applying musl patches...")

foreach(patch ${MUSL_PATCHES})
  list(APPEND MUSL_PATCH_COMMANDS
    COMMAND echo "Applying patch '${patch}'..."
    COMMAND patch -p1 -d "${MUSL}" -i ${patch}
  )
endforeach(patch)

add_custom_command(OUTPUT ${MUSL}/config.mak
  COMMAND rm -rf "${MUSL}"
  COMMAND tar xf "${MUSL_TARBALL}"
  ${MUSL_PATCH_COMMANDS}
  COMMAND cd ${MUSL} && CC=${CMAKE_C_COMPILER} ./configure --disable-shared CFLAGS=${MUSL_CFLAGS} --enable-debug
  MAIN_DEPENDENCY ${MUSL_TARBALL}
  DEPENDS ${MUSL_PATCHES}
  COMMENT "Configuring ${MUSL}"
)

# Kludge to handle parallelism when using make,
# without breaking compat when using other generators (like ninja)
if ("${CMAKE_GENERATOR}" STREQUAL "Unix Makefiles")
  set(MAKECMD $(MAKE) AR=${CMAKE_AR} RANLIB=${CMAKE_RANLIB})
else()
  set(MAKECMD make -j8 AR=${CMAKE_AR} RANLIB=${CMAKE_RANLIB})
endif()

add_custom_command(OUTPUT ${MUSL}/lib/libc.a
  COMMAND hardeningDisable=stackprotector ${MAKECMD} -C ${MUSL}
  DEPENDS ${MUSL}/config.mak
  COMMENT "Building ${MUSL}..."
)
add_custom_target(musl DEPENDS ${MUSL}/lib/libc.a)
set_directory_properties(PROPERTIES ADDITIONAL_MAKE_CLEAN_FILES "${MUSL}")

# Compile our little assembly bits into a library, then merge in musl's libc.a.
add_library(none STATIC unwind/UnwindRegistersRestore.S unwind/UnwindRegistersSave.S dso_handle.S dynamic.S)
install(TARGETS none DESTINATION lib)
set_output_directory(none BINARY_DIR ${LLVM_RUNTIME_OUTPUT_INTDIR} LIBRARY_DIR ${LLVM_LIBRARY_OUTPUT_INTDIR})
add_dependencies(none musl)
# http://stackoverflow.com/questions/3821916/how-to-merge-two-ar-static-libraries-into-one
configure_file(merge.ar.in merge.ar)
add_custom_command(TARGET none POST_BUILD
  COMMAND ${CMAKE_AR} -M <merge.ar
  COMMAND mv libnone.a.merged ${LLVM_LIBRARY_OUTPUT_INTDIR}/libnone.a
  COMMAND ${CMAKE_STRIP} --strip-debug --strip-unneeded ${LLVM_LIBRARY_OUTPUT_INTDIR}/libnone.a
  DEPENDS merge.ar
)

# Install crt bits from musl, since they are useful for static linking.
set(MUSL_ABS ${CMAKE_CURRENT_BINARY_DIR}/${MUSL})
set(CRTFILES
  ${MUSL_ABS}/lib/crt1.o
  ${MUSL_ABS}/lib/crti.o
  ${MUSL_ABS}/lib/crtn.o
  ${MUSL_ABS}/lib/rcrt1.o
  ${MUSL_ABS}/lib/Scrt1.o
)
add_custom_command(TARGET musl POST_BUILD
  COMMAND mkdir -p ${LLVM_LIBRARY_OUTPUT_INTDIR}/crt
  COMMAND cp -t ${LLVM_LIBRARY_OUTPUT_INTDIR}/crt ${CRTFILES}
)
set_property(DIRECTORY APPEND PROPERTY
  ADDITIONAL_MAKE_CLEAN_FILES "${LLVM_LIBRARY_OUTPUT_INTDIR}/crt")
install(FILES ${CRTFILES} DESTINATION lib/crt)
