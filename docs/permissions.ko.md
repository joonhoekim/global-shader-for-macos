# 다시 빌드하면 화면 기록 권한이 조용히 끊긴다

*[← README](../README.ko.md)  ·  [English](permissions.md)*

**이걸로 한 번 헤맸다.** 증상은 "시스템 설정에 권한이 분명히 켜져 있는데 아무 일도
안 일어난다"이다.

`build.sh` 가 임의 서명(`codesign -s -`)을 쓰면 지정 요구사항이 이렇게 된다:

```
designated => cdhash H"6d3a31a07290c00701e45474884eb5b0138c2657"
```

TCC 는 허가를 내줄 때 이 요구사항을 통째로 저장해 두고 다음에 다시 맞춰 본다.
그러니 **바이너리가 한 바이트만 달라져도 거절된다.** `tccd` 로그에 그대로 남는다:

```
Failed to match existing code requirement for subject
dev.jh.global-shader and service kTCCServiceScreenCapture
```

고약한 것은 이때 macOS 가 **다시 묻지 않는다**는 점이다. 항목은 이미 있으므로
체크박스는 켜진 채로 남고 앱만 거절당한다.

## 터미널에서는 되는데 Finder 에서는 안 되는 이유

같은 바이너리인데 결과가 다르다.

| 띄운 방법 | 신원 | 결과 |
|---|---|---|
| `open` · Finder · launchd | `dev.jh.global-shader` | cdhash 가 안 맞으면 거절 |
| `./build/global-shader` | 번들 ID 없음 → **터미널** | 터미널의 권한으로 통과 |

`build/global-shader` 는 심링크라 `Bundle.main` 이 `.app` 을 못 찾고, 권한이 부모
프로세스에 붙는다. 그래서 터미널에서 잘 되는 것은 앱이 권한을 가져서가 아니라
**터미널 것을 빌려 쓰는 것이다.** 로그의 `번들 ''` 이 그 표식이다.

## 고치는 법

한 번만 인증서를 만들면 이 왕복이 없어진다.

```sh
./tools/make-signing-cert.sh
tccutil reset ScreenCapture dev.jh.global-shader
./build.sh && open build/GlobalShader.app     # 다시 물어본다 → 허용
```

인증서 이름은 이 앱 것이 아니라 공용(`jh local codesign`)이다. 손으로 빌드하는
`.app` 은 대개 하나가 아니고, 이 신원이 하는 일은 앱마다 다르지 않다 — 앱마다
따로 두면 재승인해야 할 조합만 늘어난다. `GS_SIGN_ID` 로 덮을 수 있다.

요구사항이 `identifier "…" and certificate leaf H"…"` 로 바뀌므로 몇 번을 다시
빌드해도 같다. `build.sh` 는 그 인증서가 있으면 알아서 쓰고, 없으면 임의 서명으로
떨어지면서 이 안내를 찍는다. 매 빌드마다 실제로 무엇이 박혔는지도 보여 준다.

인증서 없이 버티려면 재빌드마다 `tccutil reset` 후 다시 허용하면 된다.

## 앱이 스스로 알려준다

이 실패가 유난히 조용한 이유가 있다. 창은 **첫 프레임을 받은 뒤에** 띄우므로
([안전장치](architecture.ko.md)), 캡처가 안 붙으면 창도 없고 오류도 없고 화면에 아무 변화가 없다.
게다가 Finder 로 띄우면 stderr 가 아무 데도 안 간다.

그래서 4초 안에 프레임이 안 오면 메뉴 막대 글자가 `◲⚠` 로 바뀌고, 메뉴에 이유와
고치는 법이 뜬다. `--status` 의 `capture` 로도 볼 수 있다:

```sh
global-shader --status
  {"chain":[…],"capture":"화면 기록 권한이 거절됐다",…,"fps":0.0}
```
