#!/usr/bin/env python3
"""
Run analyze_audio_quality over multiple files and emit JSON results.
"""

import argparse
import importlib.util
import json
import pathlib
import time


def load_spectre_eval(module_path):
    spec = importlib.util.spec_from_file_location("spectre_eval", module_path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main():
    parser = argparse.ArgumentParser(description="Batch audio quality analysis.")
    parser.add_argument("paths", nargs="+", help="Audio file paths to analyze.")
    parser.add_argument("--out", default="audio_quality_batch_results.json", help="Output JSON path.")
    parser.add_argument("--debug", action="store_true", help="Include debug details from analyzer.")
    parser.add_argument("--target-lufs", type=float, default=-14.0, help="Target LUFS for loudnorm delta.")
    args = parser.parse_args()

    here = pathlib.Path(__file__).resolve().parent
    analyzer = load_spectre_eval(here / "spectre_eval.py")

    results = []
    for p in args.paths:
        entry = {"path": p}
        t0 = time.time()
        try:
            res = analyzer.analyze_audio_quality(p, target_lufs=args.target_lufs, debug=args.debug)
            entry.update({
                "ok": True,
                "elapsed_s": round(time.time() - t0, 3),
                "score": res["score"],
                "grade": res["grade"],
                "recommendation": res["recommendation"],
                "is_upscaled": res["is_upscaled"],
                "fake_hires_192k_24bit": res["fake_hires_192k_24bit"],
                "dynamic_range_score": res["dynamic_range_score"],
                "lra_lu": res["lra_lu"],
                "integrated_lufs": res["integrated_lufs"],
                "true_peak_dbfs": res["true_peak_dbfs"],
                "likely_clipped_distorted": res["likely_clipped_distorted"],
                "loudness_war_victim": res["loudness_war_victim"],
                "required_gain_db": res["required_gain_db"],
                "should_apply_loudnorm": res["should_apply_loudnorm"],
                "spectrogram_summary": res["spectrogram_summary"],
                "recommendation_with_spectrogram": res["recommendation_with_spectrogram"],
            })
            if args.debug:
                entry["debug"] = res.get("debug", {})
                entry["fake_hires_details"] = res.get("fake_hires_details", {})
        except Exception as exc:
            entry.update({
                "ok": False,
                "elapsed_s": round(time.time() - t0, 3),
                "error": str(exc),
            })
        results.append(entry)

    out_path = pathlib.Path(args.out)
    out_path.write_text(json.dumps(results, indent=2, ensure_ascii=False), encoding="utf-8")

    print(f"WROTE={out_path}")
    for row in results:
        name = pathlib.Path(row["path"]).name
        if not row["ok"]:
            print(f"FAIL | {name} | {row['error']}")
            continue
        print(
            f"OK | {name} | score={row['score']:.1f} grade={row['grade']} rec={row['recommendation']} "
            f"up={int(row['is_upscaled'])} fake={int(row['fake_hires_192k_24bit'])} "
            f"LRA={row['lra_lu']} TP={row['true_peak_dbfs']} t={row['elapsed_s']}s"
        )


if __name__ == "__main__":
    main()
