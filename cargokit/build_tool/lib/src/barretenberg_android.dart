/// Noir / barretenberg-specific Android build setup for cargokit.
///
/// This is the cargokit/flutter_rust_bridge analogue of mopro's
/// `cli/src/build/android_noir.rs`. noir_flutter builds its Rust through
/// cargokit instead of the mopro CLI, so it does not inherit mopro's Android
/// fix and must replicate it here.
///
/// Why this is needed: `barretenberg-rs`'s `build.rs` chooses its prebuilt by
/// substring-matching the target triple, with the `linux` arm *before*
/// `android`. `x86_64-linux-android` contains `linux`, so it downloads the
/// glibc / libstdc++ build and links it into the Android `.so`; `dlopen` then
/// fails at runtime (`__libc_single_threaded`, `std::__cxx11::*`).
///
/// `barretenberg-rs` honors `BB_LIB_DIR` ahead of its own download, so we
/// pre-fetch the correct `barretenberg-static-<arch>-android` prebuilt, point
/// `BB_LIB_DIR` at it, and link the result with Zig — the prebuilt's libc++ is
/// `std::__1` and the NDK's is `std::__ndk1` (ABI-incompatible), so the NDK
/// linker can't be used for the final link.
///
/// Unlike mopro (which also does a second NDK-linked build to recover the
/// `.symtab` uniffi-bindgen reads), flutter_rust_bridge generates its bindings
/// from the Rust *source*, not the compiled library, so no second build is
/// needed.
///
/// Requirements: `zig` (>= 0.13) and the Android NDK on `PATH`. The minimum
/// Android API is raised to 30 (the prebuilt imports `__tls_get_addr`, API 29).
library;

import 'dart:io';

import 'package:path/path.dart' as path;

import 'util.dart';

const int barretenbergMinSdkVersion = 30;

/// Map a Rust target triple to the barretenberg Android prebuilt arch, or
/// `null` when Aztec ships no static prebuilt for it (only arm64 + x86_64).
String? bbArchForTriple(String rustTriple) {
  switch (rustTriple) {
    case 'x86_64-linux-android':
      return 'x86_64-android';
    case 'aarch64-linux-android':
      return 'arm64-android';
    default:
      return null;
  }
}

/// `true` when the crate at [manifestDir] depends on `barretenberg-rs`
/// (resolved from its `Cargo.lock`). A no-op marker for non-Noir crates.
bool crateUsesBarretenberg(String manifestDir) {
  return _barretenbergRsVersion(manifestDir) != null;
}

/// Build the extra environment a Noir crate needs to link [target] for Android:
/// `BB_LIB_DIR` pointing at the pre-fetched prebuilt, and an override of
/// cargokit's linker (`CARGO_TARGET_<triple>_LINKER`) to a Zig `cc` wrapper.
///
/// Returns an empty map when [target]'s arch has no prebuilt or the crate does
/// not use barretenberg, leaving the plain cargokit build untouched.
Future<Map<String, String>> barretenbergAndroidEnvironment({
  required String rustTriple,
  required String manifestDir,
  required String ndkPath,
  required String hostArch,
  required int minSdkVersion,
  required String buildDir,
}) async {
  final bbArch = bbArchForTriple(rustTriple);
  if (bbArch == null) {
    return {};
  }
  if (!crateUsesBarretenberg(manifestDir)) {
    return {};
  }

  final version = _barretenbergRsVersion(manifestDir);
  if (version == null) {
    throw Exception(
      'Could not resolve the barretenberg-rs version from '
      '${path.join(manifestDir, 'Cargo.lock')}; cannot fetch the correct '
      'Android prebuilt. Run `cargo generate-lockfile` in $manifestDir.',
    );
  }

  _ensureZigAvailable();

  final bbLibDir =
      await _downloadBarretenbergAndroidLib(bbArch, version, buildDir);
  final linkerWrapper = _writeZigLinkerWrapper(
    rustTriple: rustTriple,
    ndkPath: ndkPath,
    hostArch: hostArch,
    minSdkVersion: minSdkVersion,
    buildDir: buildDir,
  );

  final linkerKey =
      'cargo_target_${rustTriple.replaceAll('-', '_')}_linker'.toUpperCase();

  return {
    'BB_LIB_DIR': bbLibDir,
    // Override cargokit's NDK-clang linker wrapper: only Zig provides the
    // prebuilt's `std::__1` libc++ symbols.
    linkerKey: linkerWrapper,
  };
}

/// Resolve the pinned `barretenberg-rs` version from [manifestDir]'s
/// `Cargo.lock`. Returns `null` when the crate is not a dependency.
String? _barretenbergRsVersion(String manifestDir) {
  final lockFile = File(path.join(manifestDir, 'Cargo.lock'));
  if (!lockFile.existsSync()) {
    return null;
  }
  final lines = lockFile.readAsLinesSync();
  for (var i = 0; i < lines.length; i++) {
    if (lines[i].trim() == 'name = "barretenberg-rs"') {
      for (var j = i + 1; j < lines.length; j++) {
        final trimmed = lines[j].trim();
        if (trimmed.startsWith('version = "')) {
          return trimmed
              .substring('version = "'.length, trimmed.length - 1);
        }
        if (trimmed == '[[package]]') {
          break;
        }
      }
    }
  }
  return null;
}

/// Fetch the barretenberg Android static library for [bbArch] at [version] and
/// return the directory to expose via `BB_LIB_DIR`. Cached per version.
Future<String> _downloadBarretenbergAndroidLib(
  String bbArch,
  String version,
  String buildDir,
) async {
  // Cache key includes the version: a noir-rs bump changes the prebuilt and
  // `buildDir` is not wiped between builds, so an arch-only key would relink a
  // stale `.a`.
  final dest =
      path.join(buildDir, 'bb-android-prebuilt', '$bbArch-$version');
  final lib = File(path.join(dest, 'libbb-external.a'));
  if (lib.existsSync()) {
    return dest;
  }
  Directory(dest).createSync(recursive: true);

  final url = 'https://github.com/AztecProtocol/aztec-packages/releases/'
      'download/v$version/barretenberg-static-$bbArch.tar.gz';
  final tarball = path.join(dest, 'barretenberg-static.tar.gz');

  log.info('Downloading barretenberg Android prebuilt: $url');
  final curl = Process.runSync('curl', ['-L', '-f', '-o', tarball, url]);
  if (curl.exitCode != 0) {
    throw Exception(
      'Failed to download barretenberg Android prebuilt from $url\n'
      '${curl.stderr}',
    );
  }

  final untar = Process.runSync('tar', ['-xzf', tarball, '-C', dest]);
  if (untar.exitCode != 0) {
    throw Exception('Failed to extract barretenberg Android prebuilt\n'
        '${untar.stderr}');
  }
  File(tarball).deleteSync();

  if (!lib.existsSync()) {
    throw Exception(
      'barretenberg Android prebuilt extracted but libbb-external.a is '
      'missing in $dest',
    );
  }
  return dest;
}

/// Error early if Zig isn't on `PATH`; the prebuilt is built with Zig's libc++.
void _ensureZigAvailable() {
  bool ok;
  try {
    ok = Process.runSync('zig', ['version']).exitCode == 0;
  } catch (_) {
    ok = false;
  }
  if (!ok) {
    throw Exception(
      'Building the Noir (barretenberg) adapter for Android requires Zig on '
      'PATH (https://ziglang.org/download/). The prebuilt barretenberg static '
      "library is built with Zig's libc++ (std::__1) and must be linked with "
      "Zig so those symbols resolve at runtime; the NDK's libc++ "
      '(std::__ndk1) is ABI-incompatible.',
    );
  }
}

/// Write a Zig `cc` linker wrapper for [rustTriple] and return its path. Zig
/// provides the prebuilt's `std::__1` libc++; the trailing `-lc++_shared`
/// keeps the NDK's `std::__ndk1` libc++ for any other C++.
String _writeZigLinkerWrapper({
  required String rustTriple,
  required String ndkPath,
  required String hostArch,
  required int minSdkVersion,
  required String buildDir,
}) {
  final sysroot = path.join(
      ndkPath, 'toolchains', 'llvm', 'prebuilt', hostArch, 'sysroot');
  final api = '$minSdkVersion';

  final tripleLib = path.join(sysroot, 'usr', 'lib', rustTriple);
  final crtDir = path.join(tripleLib, api);
  final archInclude = path.join(sysroot, 'usr', 'include', rustTriple);
  final genericInclude = path.join(sysroot, 'usr', 'include');

  final outDir = Directory(path.join(buildDir, 'cargokit', 'bb-zig'))
    ..createSync(recursive: true);

  // Zig ships no Android libc, so point it at the NDK's bionic + arch headers
  // (sys_include_dir is the arch dir, where the kernel `asm/` headers live).
  final libcConf = File(path.join(outDir.path, 'zig-android-libc-$rustTriple.txt'));
  libcConf.writeAsStringSync(
    'include_dir=$genericInclude\n'
    'sys_include_dir=$archInclude\n'
    'crt_dir=$crtDir\n'
    'msvc_lib_dir=\n'
    'kernel32_lib_dir=\n'
    'gcc_dir=\n',
  );

  // `zig cc` bakes in Zig's static `__1` libc++ (resolving barretenberg's
  // `-lc++`); the trailing `-lc++_shared` keeps the NDK's `__ndk1` libc++ for
  // other C++.
  final wrapper = File(path.join(outDir.path, 'zig-android-cc-$rustTriple.sh'));
  wrapper.writeAsStringSync(
    '#!/bin/sh\n'
    'set -e\n'
    'export ZIG_LIBC="${libcConf.path}"\n'
    'exec zig cc -target $rustTriple '
    '-L "$crtDir" -L "$tripleLib" "\$@" -lc++_shared\n',
  );
  Process.runSync('chmod', ['+x', wrapper.path]);
  return wrapper.path;
}
