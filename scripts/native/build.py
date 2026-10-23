#!/usr/bin/env python3
"""Build a candidate on its native runner; never publishes or updates pins."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tarfile
import urllib.request

ROOT = Path(__file__).resolve().parents[2]
TARGETS = {
    'arm64-darwin': ('aarch64-apple-darwin', 'dylib'),
    'x86_64-darwin': ('x86_64-apple-darwin', 'dylib'),
    'x86_64-linux': ('x86_64-unknown-linux-gnu', 'so'),
    'aarch64-linux': ('aarch64-unknown-linux-gnu', 'so'),
    'x86_64-linux-musl': ('x86_64-unknown-linux-musl', 'so'),
    'aarch64-linux-musl': ('aarch64-unknown-linux-musl', 'so'),
    'x64-mingw-ucrt': ('x86_64-pc-windows-gnu', 'dll'),
}


def run(*args, **kwargs):
    print('+', ' '.join(map(str, args)), flush=True)
    return subprocess.check_output(list(map(str, args)), text=True, **kwargs)


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def acquire(name, source, work):
    pin = source['archive']
    digest = pin['sha256']
    if not re.fullmatch('[a-f0-9]{64}', digest):
        raise ValueError(f'{name}: invalid SHA-256 pin')
    archive = work / (name + '.tar')
    with urllib.request.urlopen(pin['url'], timeout=120) as response, archive.open('wb') as out:
        shutil.copyfileobj(response, out)
    if sha(archive) != digest:
        raise ValueError(f'{name}: downloaded archive SHA-256 mismatch')
    destination = work / name
    destination.mkdir()
    with tarfile.open(archive) as tar:
        # Dependencies contain no required links; reject links rather than following them.
        for entry in tar.getmembers():
            parts = Path(entry.name).parts
            if (entry.name.startswith('/') or '..' in parts or '\\' in entry.name
                    or ':' in entry.name or entry.issym() or entry.islnk()):
                raise ValueError(f'unsafe source archive entry: {entry.name}')
            if not (entry.isdir() or entry.isfile()):
                raise ValueError(f'unsupported source archive entry: {entry.name}')
        tar.extractall(destination)
    roots = list(destination.iterdir())
    if (len(roots) != 1 or not roots[0].is_dir()
            or roots[0].name != pin['extracted_root']):
        raise ValueError(f'{name}: expected one archive root')
    return roots[0]


def dependency(name, source, work, prefix, zlib_prefix=None):
    tree = acquire(name, source, work)
    build = work / (name + '-build')
    args = ['cmake', '-S', tree, '-B', build, '-G', 'Ninja',
            '-DCMAKE_BUILD_TYPE=Release', '-DCMAKE_POSITION_INDEPENDENT_CODE=ON',
            f'-DCMAKE_INSTALL_PREFIX={prefix}', '-DCMAKE_INSTALL_LIBDIR=lib',
            '-DBUILD_SHARED_LIBS=OFF']
    if name == 'libpng':
        args += ['-DPNG_SHARED=OFF', '-DPNG_STATIC=ON', '-DPNG_TESTS=OFF',
                 '-DPNG_TOOLS=OFF', f'-DZLIB_LIBRARY={zlib_prefix / "lib/libz.a"}',
                 f'-DZLIB_INCLUDE_DIR={zlib_prefix / "include"}']
    run(*args)
    run('cmake', '--build', build, '--parallel', '2')
    run('cmake', '--install', build)
    canonical = prefix / ('lib/libpng16.a' if name == 'libpng' else 'lib/libz.a')
    if not canonical.is_file():
        alternatives = [prefix / 'lib' / filename for filename in
                        (['libpng16_static.a', 'libpng_static.a'] if name == 'libpng' else ['libzlibstatic.a'])]
        matches = [path for path in alternatives if path.is_file()]
        if len(matches) != 1:
            raise ValueError(f'{name}: missing unambiguous static archive in {prefix}')
        shutil.copyfile(matches[0], canonical)


def inspect(target, library):
    if 'darwin' in target:
        arch = 'arm64' if target.startswith('arm64') else 'x86_64'
        if run('lipo', '-archs', library).strip() != arch:
            raise ValueError('wrong Mach-O architecture')
        report = run('otool', '-L', library)
        dependencies = [line.strip().split()[0] for line in report.splitlines()[2:]]
        if dependencies != ['/usr/lib/libSystem.B.dylib']:
            raise ValueError(f'unexpected Mach-O dependencies: {dependencies}')
        return report
    report = run('objdump', '-p', library)
    if target == 'x64-mingw-ucrt':
        imports = re.findall(r'DLL Name:\s*(\S+)', report, re.I)
        if not imports or any('msvcrt' in name.lower() for name in imports):
            raise ValueError(f'MSVCRT closure is not UCRT-compatible: {imports}')
        if not any('ucrtbase' in name.lower() or 'api-ms-win-crt-' in name.lower() for name in imports):
            raise ValueError('missing UCRT runtime import proof')
        allowed = re.compile(r'^(kernel32|ntdll|advapi32|bcrypt|userenv|ws2_32|shell32|ole32|synchronization|ucrtbase)\.dll$|^api-ms-win-', re.I)
        if any(not allowed.search(name) for name in imports):
            raise ValueError(f'non-system DLL dependency: {imports}')
        if 'pei-x86-64' not in report:
            raise ValueError('wrong PE architecture')
    else:
        header = run('readelf', '-h', library)
        machine = 'AArch64' if target.startswith('aarch64') else 'Advanced Micro Devices X86-64'
        if machine not in header:
            raise ValueError('wrong ELF architecture')
        needed = re.findall(r'NEEDED\s+(\S+)', report)
        allowed = (r'libc\.musl-(x86_64|aarch64)\.so\.1' if 'musl' in target else
                   r'(libc|libm|libdl|libpthread|librt)\.so\.[0-9]+|ld-linux[^/]*\.so\.[0-9]+')
        if not needed or any(not re.fullmatch(allowed, name) for name in needed):
            raise ValueError(f'non-system or wrong-libc ELF closure: {needed}')
    return report


def build(target, work, output):
    triple, suffix = TARGETS[target]
    # A fresh directory prevents reuse of an archive from a different target or pin.
    work.mkdir(parents=True, exist_ok=False)
    output.mkdir(parents=True, exist_ok=True)
    sources = json.loads(run('ruby', '-ryaml', '-rjson', '-e',
                             'puts JSON.generate(YAML.safe_load_file(ARGV[0]))',
                             ROOT / 'vendor/manifest.yml'))['sources']
    zlib, png = work / 'zlib-prefix', work / 'png-prefix'
    dependency('zlib', sources['zlib'], work, zlib)
    dependency('libpng', sources['libpng'], work, png, zlib)
    env = os.environ.copy()
    flags = '-C target-feature=-crt-static' if 'musl' in target else ''
    if suffix == 'dll':
        flags = '-C linker=gcc -C link-self-contained=no'
    env['RUSTFLAGS'] = flags
    env['CARGO_TARGET_DIR'] = str(work / 'cargo')
    run('cargo', '+1.85.0', 'rustc', '--crate-type', 'staticlib', '--locked', '--release', '--target', triple,
        '--manifest-path', ROOT / 'native/svgpng_renderer/Cargo.toml', '-j2', env=env)
    archive = work / 'cargo' / triple / 'release/libsvgpng_renderer.a'
    library = output / f'svgpng.{suffix}'
    args = ['gcc' if suffix != 'dylib' else 'clang', '-std=c11', '-O2', '-fPIC',
            '-Wall', '-Wextra', '-Werror', '-pedantic', '-DPNG_STATIC', f'-I{png / "include"}', f'-I{zlib / "include"}',
            ROOT / 'native/svgpng_shim/rgba.c', ROOT / 'native/svgpng_shim/encoder.c']
    if suffix == 'dylib':
        args += ['-dynamiclib', f'-Wl,-force_load,{archive}']
    else:
        args += ['-shared', '-Wl,--whole-archive', archive, '-Wl,--no-whole-archive']
    args += [png / 'lib/libpng16.a', zlib / 'lib/libz.a']
    if suffix == 'dylib':
        args += ['-lSystem', '-lc', '-lm']
    elif suffix == 'dll':
        args += ['-static-libgcc', '-lws2_32', '-luserenv', '-lbcrypt', '-lntdll']
    else:
        args += ['-static-libgcc', '-ldl', '-lpthread', '-lm']
    run(*args, '-o', library)
    closure = inspect(target, library)
    (output / 'closure.txt').write_text(closure)
    provenance = {'target': target, 'rust_target': triple, 'library_sha256': sha(library),
                  'commit': run('git', '-C', ROOT, 'rev-parse', 'HEAD').strip(),
                  'source_manifest_sha256': sha(ROOT / 'vendor/manifest.yml'),
                  'cargo_lock_sha256': sha(ROOT / 'native/svgpng_renderer/Cargo.lock'),
                  'rustc': run('rustc', '+1.85.0', '-Vv'), 'link_command': list(map(str, args)),
                  'source_pins': {name: sources[name]['archive'] for name in ('libpng', 'zlib')}}
    (output / 'provenance.json').write_text(json.dumps(provenance, indent=2) + '\n')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('target', choices=TARGETS)
    parser.add_argument('--work', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    options = parser.parse_args()
    build(options.target, options.work.resolve(), options.output.resolve())
