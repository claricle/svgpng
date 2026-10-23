"""Public driver regressions; no compiler or network needed."""
import hashlib
import io
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest.mock import patch

import build


class SourceTests(unittest.TestCase):
    def archive(self, name, content=b'pin'):
        data = io.BytesIO()
        with tarfile.open(fileobj=data, mode='w') as tar:
            entry = tarfile.TarInfo(name)
            entry.size = len(content)
            tar.addfile(entry, io.BytesIO(content))
        return data.getvalue()

    def acquire(self, work, data, digest=None):
        source = {'archive': {'url': 'https://example.invalid/pinned.tar',
                              'sha256': digest or hashlib.sha256(data).hexdigest(),
                              'extracted_root': 'release'}}
        with patch('build.urllib.request.urlopen', return_value=io.BytesIO(data)):
            return build.acquire('test', source, Path(work))

    def test_verified_archive_extracts_exact_bytes(self):
        with tempfile.TemporaryDirectory() as work:
            tree = self.acquire(work, self.archive('release/input'))
            self.assertEqual((tree / 'input').read_bytes(), b'pin')

    def test_changed_archive_rejected_before_extract(self):
        with tempfile.TemporaryDirectory() as work:
            with self.assertRaisesRegex(ValueError, 'SHA-256 mismatch'):
                self.acquire(work, self.archive('release/input'), '0' * 64)
            self.assertFalse((Path(work) / 'test').exists())

    def test_traversal_rejected_without_touching_neighbor(self):
        with tempfile.TemporaryDirectory() as outer:
            work = Path(outer) / 'work'
            work.mkdir()
            neighbor = Path(outer) / 'keep'
            neighbor.write_bytes(b'preserved')
            with self.assertRaisesRegex(ValueError, 'unsafe source archive'):
                self.acquire(work, self.archive('../keep', b'corrupted'))
            self.assertEqual(neighbor.read_bytes(), b'preserved')


class DependencyTests(unittest.TestCase):
    def test_windows_zlib_static_archive_is_staged_without_shared_build(self):
        with tempfile.TemporaryDirectory() as work:
            root = Path(work)
            prefix = root / 'prefix'
            (prefix / 'lib').mkdir(parents=True)
            (prefix / 'lib/libzs.a').write_bytes(b'static archive')
            with patch('build.acquire', return_value=root / 'source'), patch('build.run') as run:
                build.dependency('zlib', {}, root, prefix)
            self.assertEqual((prefix / 'lib/libz.a').read_bytes(), b'static archive')
            self.assertIn('-DZLIB_BUILD_SHARED=OFF', run.call_args_list[0].args)


class ClosureTests(unittest.TestCase):
    def test_ucrt_closure_accepted(self):
        report = ('pei-x86-64\nDLL Name: KERNEL32.dll\nDLL Name: ucrtbase.dll\n'
                  'DLL Name: bcryptprimitives.dll\nDLL Name: api-ms-win-core-synch-l1-2-0.dll\n')
        with patch('build.run', return_value=report):
            self.assertEqual(build.inspect('x64-mingw-ucrt', 'library'), report)

    def test_ucrt_rejects_external_runtime_dll(self):
        report = 'pei-x86-64\nDLL Name: ucrtbase.dll\nDLL Name: libgcc_s_seh-1.dll\n'
        with patch('build.run', return_value=report):
            with self.assertRaisesRegex(ValueError, 'non-system DLL'):
                build.inspect('x64-mingw-ucrt', 'library')

    def test_msvcrt_rejected_even_when_ucrt_present(self):
        report = 'pei-x86-64\nDLL Name: ucrtbase.dll\nDLL Name: msvcrt.dll\n'
        with patch('build.run', return_value=report):
            with self.assertRaisesRegex(ValueError, 'MSVCRT'):
                build.inspect('x64-mingw-ucrt', 'library')

    def test_dynamic_png_rejected(self):
        with patch('build.run', side_effect=['NEEDED libc.so.6\nNEEDED libpng16.so.16',
                                             'Advanced Micro Devices X86-64']):
            with self.assertRaisesRegex(ValueError, 'ELF closure'):
                build.inspect('x86_64-linux', 'library')

    def test_musl_rejects_gnu_libc(self):
        with patch('build.run', side_effect=['NEEDED libc.so.6', 'AArch64']):
            with self.assertRaisesRegex(ValueError, 'wrong-libc'):
                build.inspect('aarch64-linux-musl', 'library')

    def test_musl_preserves_target_architecture(self):
        with patch('build.run', side_effect=['NEEDED libc.musl-aarch64.so.1', 'AArch64',
                                             '\n'.join('000 T ' + name for name in build.ABI_SYMBOLS)]):
            self.assertIn('musl-aarch64', build.inspect('aarch64-linux-musl', 'library'))

    def test_elf_rejects_codec_symbols_that_allow_interposition(self):
        symbols = '\n'.join('000 T ' + name for name in build.ABI_SYMBOLS | {'zlibVersion'})
        with patch('build.run', side_effect=['NEEDED libc.so.6',
                                             'Advanced Micro Devices X86-64', symbols]):
            with self.assertRaisesRegex(ValueError, 'non-private'):
                build.inspect('x86_64-linux', 'library')


if __name__ == '__main__':
    unittest.main()
