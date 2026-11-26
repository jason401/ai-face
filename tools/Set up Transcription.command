#!/bin/zsh
# AI Face "Transcribe": installs what AI Face Listener needs to turn speech into text on this Mac.
#   - whisper.cpp (Homebrew formula whisper-cpp): whisper-server, which keeps the model loaded
#   - the Whisper large-v3-turbo model (q5_0, about 550 MB) and the Silero VAD model (about 1 MB),
#     into ~/Library/Application Support/AI Face/Listener/models
#   - an empty glossary.txt there: names and terms Whisper should spell right, one per line
# Nothing here needs your password, and transcribing never sends audio anywhere.
SUPPORT="$HOME/Library/Application Support/AI Face/Listener"
MODELS="$SUPPORT/models"
HF=https://huggingface.co
if defaults read -g AppleLanguages 2>/dev/null | sed -n 2p | grep -q '"\{0,1\}ko'; then KO=1; else KO=; fi
msg() { if [ -n "$KO" ]; then echo "$1"; else echo "$2"; fi }
bye() { if [ -n "$KO" ]; then read "?엔터를 누르면 창이 닫힙니다."; else read "?Press Return to close."; fi; exit $1; }

BREW=""
for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do [ -x "$b" ] && BREW="$b" && break; done
if [ -z "$BREW" ]; then
  msg "Homebrew가 없어요. https://brew.sh 에서 설치한 뒤 다시 실행하세요." \
      "Homebrew is missing. Install it from https://brew.sh, then run this again."
  bye 1
fi
if [ ! -x /opt/homebrew/bin/whisper-server ] && [ ! -x /usr/local/bin/whisper-server ]; then
  msg "whisper.cpp 설치 중…" "Installing whisper.cpp…"
  "$BREW" install whisper-cpp || bye 1
fi

mkdir -p "$MODELS"
fetch() {   # name, URL: download to name.part, then move into place (a broken download is never used)
  if [ -s "$MODELS/$1" ]; then return 0; fi
  msg "$1 받는 중…" "Downloading $1…"
  /usr/bin/curl -fL --progress-bar -o "$MODELS/$1.part" "$2" && mv "$MODELS/$1.part" "$MODELS/$1"
}
fetch ggml-large-v3-turbo-q5_0.bin "$HF/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin" || bye 1
fetch ggml-silero-v5.1.2.bin "$HF/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin" || bye 1

if [ ! -f "$SUPPORT/glossary.txt" ]; then
  printf '%s\n' '# Names and terms Whisper should spell right, one per line (lines starting with # are ignored).' \
    '# Example:' '# LiNbO3' '# hydrophone' > "$SUPPORT/glossary.txt"
fi
msg "준비 끝. AI Face 패널 → 받아쓰기 → 받아쓰기 시작." "Done. AI Face panel → Transcribe → Start transcribing."
msg "용어 사전: $SUPPORT/glossary.txt" "Glossary: $SUPPORT/glossary.txt"
bye 0
