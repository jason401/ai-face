"""Verify iCloud access from the staged, signed app without enabling sync."""
import pathlib
import subprocess

app = pathlib.Path(__file__).resolve().parents[1] / "AI Face.update.app"
subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], check=True)
result = subprocess.run([str(app / "Contents/MacOS/AIFace"), "--history-icloud-probe"],
                        capture_output=True, text=True, timeout=40)
print(result.stdout, end="")
print(result.stderr, end="")
raise SystemExit(result.returncode)
