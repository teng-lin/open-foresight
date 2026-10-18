import sys
from pathlib import Path
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
from test_packaged_note_enhancement import enhanced, generation_environment


class PackagedNoteContentTest(unittest.TestCase):
    def check_output(self, text):
        return enhanced(
            {
                "artifacts": [
                    {
                        "id": 2,
                        "kind": "enhanced_notes",
                        "edited": None,
                        "generated": text,
                    }
                ]
            },
            "Friday",
        )

    def test_generation_backend_selection_is_explicit_and_does_not_change_runtime_paths(
        self,
    ):
        original = {"HOME": "/tmp/isolated", "PATH": "/usr/bin:/bin"}
        self.assertEqual(generation_environment(original, None), original)
        for backend in ("cpu", "gpu"):
            self.assertEqual(
                generation_environment(original, backend),
                {**original, "FORESIGHT_LITERT_BACKEND": backend},
            )
        self.assertNotIn("FORESIGHT_LITERT_BACKEND", original)
        with self.assertRaises(ValueError):
            generation_environment(original, "automatic")

    def test_updated_primary_deadline(self):
        self.check_output("- **Mira:** Draft deadline Friday, not Tuesday.")
        self.check_output("- **Mira:** Draft deadline changed from Tuesday to Friday.")

    def test_stale_primary_with_friday_only_in_missed_topics_is_rejected(self):
        with self.assertRaises(AssertionError):
            self.check_output(
                "- Mira sends draft Tuesday.\n### 💡 Potential Important Topics Not In Notes\n- Friday correction"
            )

    def test_friday_for_someone_else_is_rejected(self):
        with self.assertRaises(AssertionError):
            self.check_output("- Mira sends draft Tuesday; Theo reviews Friday.")

    def test_stale_primary_even_with_updated_bullet_is_rejected(self):
        with self.assertRaises(AssertionError):
            self.check_output("- Mira sends draft Tuesday.\n- Mira sends draft Friday.")

    def test_negated_friday_deadline_is_rejected(self):
        with self.assertRaises(AssertionError):
            self.check_output("- Mira will not send the draft on Friday.")


if __name__ == "__main__":
    unittest.main()
