import sys
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT / "lib" / "py"))

import audlint_analyze  # noqa: E402


def _segment_sample(
    *,
    cutoff_hz: float | None,
    classification: str,
    target_sr: int,
    hf_present: bool = False,
    boundary_ambiguous: bool = False,
    classification_reason: str = "test",
) -> dict[str, object]:
    return {
        "cutoff_hz": cutoff_hz,
        "classification": classification,
        "decision_target_sr_hint": target_sr,
        "hf_present": hf_present,
        "boundary_ambiguous": boundary_ambiguous,
        "classification_reason": classification_reason,
    }


class AudlintAnalyzeLogicTests(unittest.TestCase):
    def test_normal_flac_prefers_fast_strategy(self) -> None:
        meta = audlint_analyze.TrackMeta(
            sr=44100.0,
            dur=240.0,
            bits=16,
            channels=2,
            analysis_sr=44100,
            codec="flac",
            size_bytes=45 * 1024 * 1024,
            has_sibling_cue=False,
            prefer_ffmpeg_first=False,
        )
        strategy, reason = audlint_analyze.choose_analysis_strategy("/tmp/album.flac", meta)
        self.assertEqual(strategy, audlint_analyze.ANALYSIS_STRATEGY_FAST)
        self.assertEqual(reason, "normal_source")

    def test_large_cue_backed_flac_prefers_segment_strategy(self) -> None:
        meta = audlint_analyze.TrackMeta(
            sr=96000.0,
            dur=2400.0,
            bits=24,
            channels=2,
            analysis_sr=96000,
            codec="flac",
            size_bytes=900 * 1024 * 1024,
            has_sibling_cue=True,
            prefer_ffmpeg_first=False,
        )
        strategy, reason = audlint_analyze.choose_analysis_strategy("/tmp/image.flac", meta)
        self.assertEqual(strategy, audlint_analyze.ANALYSIS_STRATEGY_SEGMENT)
        self.assertIn("cue_backed_large_image", reason)

    def test_expensive_dsd_codec_prefers_segment_strategy(self) -> None:
        meta = audlint_analyze.TrackMeta(
            sr=2822400.0,
            dur=480.0,
            bits=24,
            channels=2,
            analysis_sr=192000,
            codec="dsd_lsbf",
            size_bytes=650 * 1024 * 1024,
            has_sibling_cue=False,
            prefer_ffmpeg_first=True,
        )
        strategy, reason = audlint_analyze.choose_analysis_strategy("/tmp/image.dsf", meta)
        self.assertEqual(strategy, audlint_analyze.ANALYSIS_STRATEGY_SEGMENT)
        self.assertIn("expensive_codec:dsd_lsbf", reason)

    def test_segment_confidence_allows_consistent_small_samples(self) -> None:
        confidence = audlint_analyze.analysis_confidence(
            [19850.0, 19880.0, 19820.0, 19860.0],
            4,
            audlint_analyze.ANALYSIS_STRATEGY_SEGMENT,
        )
        self.assertEqual(confidence, "high")

    def test_segment_summary_accepts_consistent_keep_source_majority(self) -> None:
        meta = audlint_analyze.TrackMeta(
            sr=96000.0,
            dur=3600.0,
            bits=24,
            channels=2,
            analysis_sr=96000,
            codec="wavpack",
            size_bytes=900 * 1024 * 1024,
            has_sibling_cue=True,
            prefer_ffmpeg_first=True,
        )
        summary = audlint_analyze.summarize_segment_samples(
            [
                _segment_sample(cutoff_hz=43500.0, classification="full-band", target_sr=96000),
                _segment_sample(cutoff_hz=42900.0, classification="full-band", target_sr=96000),
                _segment_sample(cutoff_hz=44100.0, classification="full-band", target_sr=96000),
            ],
            meta,
            500,
        )
        self.assertEqual(summary["decision_confidence"], "high")
        self.assertEqual(summary["decision_reason"], "accepted_by_consistency")
        self.assertFalse(summary["allow_fake_upscale"])

    def test_segment_summary_blocks_false_positive_downgrade_when_hf_contradicts(self) -> None:
        meta = audlint_analyze.TrackMeta(
            sr=192000.0,
            dur=3600.0,
            bits=24,
            channels=2,
            analysis_sr=192000,
            codec="wavpack",
            size_bytes=900 * 1024 * 1024,
            has_sibling_cue=False,
            prefer_ffmpeg_first=True,
        )
        summary = audlint_analyze.summarize_segment_samples(
            [
                _segment_sample(cutoff_hz=14900.0, classification="cutoff-limited", target_sr=44100),
                _segment_sample(cutoff_hz=15100.0, classification="cutoff-limited", target_sr=44100),
                _segment_sample(
                    cutoff_hz=45500.0,
                    classification="full-band",
                    target_sr=192000,
                    hf_present=True,
                    classification_reason="hf_presence_guard",
                ),
            ],
            meta,
            500,
        )
        decision = audlint_analyze.resolve_recode_decision(15000.0, 192000.0, 500, summary)
        self.assertFalse(summary["allow_fake_upscale"])
        self.assertEqual(summary["decision_confidence"], "medium")
        self.assertEqual(decision["decision"], "keep_source")
        self.assertTrue(decision["downgrade_guarded"])

    def test_segment_summary_allows_true_fake_upscale_when_consistent(self) -> None:
        meta = audlint_analyze.TrackMeta(
            sr=96000.0,
            dur=1800.0,
            bits=24,
            channels=2,
            analysis_sr=96000,
            codec="flac",
            size_bytes=500 * 1024 * 1024,
            has_sibling_cue=False,
            prefer_ffmpeg_first=False,
        )
        summary = audlint_analyze.summarize_segment_samples(
            [
                _segment_sample(cutoff_hz=18200.0, classification="cutoff-limited", target_sr=44100),
                _segment_sample(cutoff_hz=17950.0, classification="cutoff-limited", target_sr=44100),
                _segment_sample(cutoff_hz=18120.0, classification="cutoff-limited", target_sr=44100),
                _segment_sample(cutoff_hz=18040.0, classification="cutoff-limited", target_sr=44100),
            ],
            meta,
            500,
        )
        decision = audlint_analyze.resolve_recode_decision(18050.0, 96000.0, 500, summary)
        self.assertTrue(summary["allow_fake_upscale"])
        self.assertIn(summary["decision_confidence"], {"medium", "high"})
        self.assertEqual(decision["decision"], "downgrade_fake_upscale")
        self.assertEqual(decision["target_sr"], 44100)

    def test_segment_summary_falls_back_on_family_inconsistency(self) -> None:
        meta = audlint_analyze.TrackMeta(
            sr=192000.0,
            dur=2400.0,
            bits=24,
            channels=2,
            analysis_sr=192000,
            codec="wavpack",
            size_bytes=800 * 1024 * 1024,
            has_sibling_cue=False,
            prefer_ffmpeg_first=True,
        )
        summary = audlint_analyze.summarize_segment_samples(
            [
                _segment_sample(cutoff_hz=18100.0, classification="cutoff-limited", target_sr=44100),
                _segment_sample(cutoff_hz=17950.0, classification="cutoff-limited", target_sr=44100),
                _segment_sample(cutoff_hz=23200.0, classification="cutoff-limited", target_sr=48000),
                _segment_sample(cutoff_hz=22950.0, classification="cutoff-limited", target_sr=48000),
            ],
            meta,
            500,
        )
        self.assertEqual(summary["decision_confidence"], "low")
        self.assertEqual(summary["decision_reason"], "fallback_due_to_family_inconsistency")

    def test_48k_source_near_nyquist_stays_48_family(self) -> None:
        decision = audlint_analyze.resolve_recode_decision(21750.0, 48000.0, 500)
        self.assertEqual(decision["standard_family_sr"], 48000)
        self.assertFalse(decision["fake_upscale"])
        self.assertEqual(decision["target_sr"], 48000)

    def test_48k_source_clear_cd_band_downgrades_to_44k(self) -> None:
        decision = audlint_analyze.resolve_recode_decision(18000.0, 48000.0, 500)
        self.assertEqual(decision["standard_family_sr"], 44100)
        self.assertTrue(decision["fake_upscale"])
        self.assertEqual(decision["target_sr"], 44100)

    def test_hires_cd_band_downgrades_to_44k_family(self) -> None:
        decision = audlint_analyze.resolve_recode_decision(20000.0, 96000.0, 500)
        self.assertEqual(decision["standard_family_sr"], 44100)
        self.assertTrue(decision["fake_upscale"])
        self.assertEqual(decision["target_sr"], 44100)

    def test_hires_48_band_downgrades_to_48k_family(self) -> None:
        decision = audlint_analyze.resolve_recode_decision(23000.0, 96000.0, 500)
        self.assertEqual(decision["standard_family_sr"], 48000)
        self.assertTrue(decision["fake_upscale"])
        self.assertEqual(decision["target_sr"], 48000)

    def test_hires_44_family_selects_88k_target(self) -> None:
        decision = audlint_analyze.resolve_recode_decision(43000.0, 176400.0, 500)
        self.assertEqual(decision["standard_family_sr"], 44100)
        self.assertTrue(decision["fake_upscale"])
        self.assertEqual(decision["target_sr"], 88200)

    def test_ultrahires_48_family_selects_192k_target(self) -> None:
        decision = audlint_analyze.resolve_recode_decision(70000.0, 384000.0, 500)
        self.assertEqual(decision["standard_family_sr"], 48000)
        self.assertTrue(decision["fake_upscale"])
        self.assertEqual(decision["target_sr"], 192000)

    def test_genuine_hires_keeps_source_family(self) -> None:
        decision = audlint_analyze.resolve_recode_decision(70000.0, 192000.0, 500)
        self.assertEqual(decision["standard_family_sr"], 48000)
        self.assertFalse(decision["fake_upscale"])
        self.assertEqual(decision["target_sr"], 192000)

    def test_genuine_ultrahires_caps_to_192k_ceiling(self) -> None:
        decision = audlint_analyze.resolve_recode_decision(110000.0, 384000.0, 500)
        self.assertEqual(decision["source_family_sr"], 48000)
        self.assertFalse(decision["fake_upscale"])
        self.assertEqual(decision["target_sr"], 192000)
        self.assertEqual(decision["decision"], "cap_highres_ceiling")

    def test_dsd_like_source_caps_to_176k_ceiling_without_fake_flag(self) -> None:
        decision = audlint_analyze.resolve_recode_decision(None, 2822400.0, 500)
        self.assertEqual(decision["source_family_sr"], 44100)
        self.assertFalse(decision["fake_upscale"])
        self.assertEqual(decision["target_sr"], 176400)
        self.assertEqual(decision["decision"], "cap_highres_ceiling")


if __name__ == "__main__":
    unittest.main()
