#!/bin/zsh
# AI Face "Keep awake": lets the app keep a MacBook awake with the lid closed.
# Installs (or removes) one sudoers rule that allows exactly these two commands without a
# password, for this user only:
#     /usr/bin/pmset -a disablesleep 1      (stay awake, even with the lid closed)
#     /usr/bin/pmset -a disablesleep 0      (back to normal)
# Nothing else gets root. Your password is typed here, in Terminal, and never stored.
RULE=/etc/sudoers.d/aiface-keepawake
ME="$(id -un)"
if defaults read -g AppleLanguages 2>/dev/null | sed -n 2p | grep -q '"\{0,1\}ko'; then KO=1; else KO=; fi
msg() { if [ -n "$KO" ]; then echo "$1"; else echo "$2"; fi }
bye() { if [ -n "$KO" ]; then read "?엔터를 누르면 창이 닫힙니다."; else read "?Press Return to close."; fi; exit $1; }

msg "AI Face 깨어 있기 설정" "AI Face keep awake setup"
echo
if [ -f "$RULE" ] || sudo -n -l /usr/bin/pmset -a disablesleep 0 >/dev/null 2>&1; then
  msg "이미 설정되어 있어요. 지우려면 r, 그대로 두려면 엔터:" "Already set up. Type r to remove it, or Return to keep it:"
  read ANSWER
  if [ "$ANSWER" = "r" ] || [ "$ANSWER" = "R" ]; then
    msg "관리자 비밀번호를 입력하세요 (화면에 안 보여요)." "Enter your Mac password (it is not shown)."
    sudo /usr/bin/pmset -a disablesleep 0 && sudo rm -f "$RULE" || bye 1
    if sudo -k; sudo -n /usr/bin/pmset -a disablesleep 0 >/dev/null 2>&1; then
      msg "지웠지만 다른 규칙이 아직 허용하고 있어요: /etc/sudoers.d 를 확인하세요." \
          "Removed, but another rule still allows it: check /etc/sudoers.d."
    else
      msg "지웠습니다. 깨어 있기는 이제 쓸 수 없어요." "Removed. Keep awake is no longer available."
    fi
  fi
  bye 0
fi

msg "이 규칙을 설치해요 (이 사용자, 두 명령만):" "This rule will be installed (this user, these two commands only):"
LINE="$ME ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1"
echo "    $LINE"
echo
TMP="$(mktemp)"
echo "$LINE" > "$TMP"
if ! /usr/sbin/visudo -cf "$TMP" >/dev/null; then
  msg "규칙 검사에 실패해서 설치하지 않았어요." "The rule did not pass the check, so nothing was installed."
  rm -f "$TMP"; bye 1
fi
msg "관리자 비밀번호를 입력하세요 (화면에 안 보여요)." "Enter your Mac password (it is not shown)."
if ! sudo /usr/bin/install -m 0440 -o root -g wheel "$TMP" "$RULE"; then
  rm -f "$TMP"
  msg "설치하지 못했어요." "It was not installed."
  bye 1
fi
rm -f "$TMP"
sudo -k   # forget the password now: the check below must work without it
if sudo -n /usr/bin/pmset -a disablesleep 0 >/dev/null 2>&1; then
  msg "완료! AI Face 메뉴 → 깨어 있기에서 켜고 끌 수 있어요." "Done! Turn it on and off in the AI Face menu → Keep awake."
  bye 0
fi
msg "설치했지만 확인에 실패했어요. 다시 실행해 보세요." "Installed, but the check failed. Try running this again."
bye 1
