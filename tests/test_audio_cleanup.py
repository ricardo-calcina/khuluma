"""Exercise actual audio expiry and refusal boundaries; retain fixture roots."""
import importlib.util
import os
from pathlib import Path
import tempfile
import time
import unittest
import sys

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('audio_cleanup', Path(__file__).resolve().parents[1] / 'bin/khuluma-lib/audio_cleanup.py')
audio = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audio)


class AudioCleanupTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix='khuluma-audio-test-'))
        print('Retained audio fixtures:', self.root)

    def wav(self, name):
        path = self.root / name
        path.write_bytes(b'RIFF test audio')
        return path

    def test_only_expired_wavs_are_deleted_at_48_hours(self):
        old = self.wav('old.wav')
        recent = self.wav('recent.wav')
        meta = self.wav('old.meta')
        transcript = self.wav('old.json')
        now = time.time()
        for path in (old, meta, transcript):
            os.utime(path, (now - 48 * 3600 - 60,) * 2)
        os.utime(recent, (now - 48 * 3600 + 60,) * 2)
        audio.prune(self.root, 2)
        self.assertFalse(old.exists())
        self.assertTrue(all(p.exists() for p in (recent, meta, transcript)))

    def test_working_wav_is_deleted(self):
        wav = self.wav('khuluma-take.wav')
        audio.delete_audio(wav, [self.root], temporary=True)
        self.assertFalse(wav.exists())
        audio.delete_audio(wav, [self.root], temporary=True)  # replay is harmless

    def test_cli_scratch_audio_is_deleted(self):
        for name in ('khuluma-app-take.ABC123', 'khuluma-tail-pad.ABC123.wav', 'khuluma-prime.ABC123.wav'):
            wav = self.wav(name)
            audio.delete_audio(wav, [self.root], temporary=True)
            self.assertFalse(wav.exists())
        tail_dir = self.root / 'khuluma-tail-rescue.ABC123'
        tail_dir.mkdir()
        tail = tail_dir / 'tail.wav'
        tail.write_bytes(b'RIFF tail audio')
        audio.delete_audio(tail, [tail_dir], temporary=True)
        self.assertFalse(tail.exists())

    def test_refuses_unrelated_files_symlinks_hardlinks_and_directories(self):
        original = self.wav('original.wav')
        other = self.wav('khuluma-outside.wav')
        json = self.wav('khuluma-transcript.json')
        link = self.root / 'khuluma-link.wav'
        link.symlink_to(original)
        hardlink = self.root / 'khuluma-hardlink.wav'
        os.link(original, hardlink)
        directory = self.root / 'khuluma-folder.wav'
        directory.mkdir()
        for path, roots in ((other, [self.root / 'different']), (json, [self.root]),
                            (link, [self.root]), (hardlink, [self.root]),
                            (directory, [self.root]), (original, [self.root])):
            with self.subTest(path=path):
                with self.assertRaises(ValueError):
                    audio.delete_audio(path, roots, temporary=True)
                self.assertTrue(path.exists())


if __name__ == '__main__':
    unittest.main()
