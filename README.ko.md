# global-shader

[![ci](https://github.com/joonhoekim/global-shader-for-macos/actions/workflows/ci.yml/badge.svg)](https://github.com/joonhoekim/global-shader-for-macos/actions/workflows/ci.yml)
[![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

macOS 판 하이프랜드 `decoration:screen_shader`.

렌더링이 끝난 화면 한 장에 프래그먼트 셰이더를 한 번 더 건다. 바탕도 메뉴 막대도
창도 전부 같은 유리 뒤로 들어간다.

ScreenCaptureKit 으로 화면을 찍고, GLSL 을 Metal 로 옮기고, 그 결과를 화면 전체에
도로 그린다. 목표는 하이프랜드 세션에서 쓰던 `.frag` 을 **한 글자도 안 고치고**
그대로 돌리는 것이다 — 같은 파일이 리눅스에서도 계속 돈다.

*[English documentation](README.md)*

> **내려받는 판은 없다.** 뒤에 유료 Apple Developer 계정이 없어서 건네줄 공증된
> `.app` 이 없다 — 공증 안 된 앱은 Gatekeeper 가 막는다. 대신 있는 것은 쓰는
> 기계에서 직접 빌드하는 탭이다. 그러면 Gatekeeper 가 볼 것이 없다.

## 설치

```sh
brew tap joonhoekim/global-shader https://github.com/joonhoekim/global-shader-for-macos
brew install joonhoekim/global-shader/global-shader
open "$(brew --prefix global-shader)/GlobalShader.app"
```

`glslang` 과 `spirv-cross` 는 의존성으로 따라온다. 처음 띄울 때는 번들에서 띄운다.
맨 바이너리는 자기를 띄운 쪽의 화면 기록 권한을 빌려 쓰고, 번들은 자기 권한을 쥔다.

업그레이드는 매번 앱을 다시 빌드하는데, 홈브루 빌드는 키체인에 닿을 수 없어서 임의
서명이 된다. 그러면 macOS 는 이제 없는 서명에 권한을 묶어 둔 채로 남는다 —
체크박스는 켜져 있는데 캡처가 멈춘다. 다시 허용하는 데 두 줄, 신원을 직접 하나
만들어 두면 `codesign` 한 줄이다. 두 방법과 왜 cask 가 아니라 formula 인지는
[홈브루로 설치하기](docs/install.ko.md) 에 있다.

## 빌드

이걸 만지거나, 홈브루를 건너뛰려면. macOS 13 이상, Xcode 명령줄 도구, 그리고
셰이더 도구 둘.

```sh
brew install glslang spirv-cross

git clone https://github.com/joonhoekim/global-shader-for-macos
cd global-shader-for-macos
./build.sh
```

홈브루 대신 `nix` 를 쓴다면:

```sh
nix shell nixpkgs#glslang nixpkgs#spirv-cross -c ./build.sh
```

`build.sh` 는 Xcode 프로젝트가 아니라 `swiftc` 한 줄에 번들 묶기다. 먼저 두 파일을
만들고(도구 경로와 버전, 그리고 번역 표) 컴파일한 뒤 `GlobalShader.app` 으로 묶고
서명한다. 번들로 묶는 것이 중요하다 — macOS 는 화면 기록 권한을 프로세스가 아니라
코드 서명 정체성에 붙이므로, 알맹이 바이너리만 돌리면 앱이 자기 권한을 갖는 게
아니라 터미널 것을 빌려 쓰게 된다.

빌드는 arm64 하나만 낸다. `GS_ARCHS="arm64 x86_64" ./build.sh` 로 universal 이
되지만 인텔 맥에서 실제로 돌려 본 적은 없다 — CI 가 컴파일까지만 확인한다.

## 처음 띄울 때

```sh
open build/GlobalShader.app
```

macOS 가 화면 기록 권한을 물어본다. 허용하고 메뉴 막대에서 `◲` 를 찾으면 된다 —
체인 순서, 손잡이 슬라이더, 프로필, 설정이 전부 그 안에 있다.

권한을 줬는데도 아무 일이 안 일어나면 재빌드 함정에 걸린 것이다. 임의 서명은 빌드
때마다 바뀌는데 TCC 는 허가를 옛 서명에 묶어 두므로, 체크박스는 켜진 채로 앱만
조용히 거절당한다. [아예 없애는 법](docs/permissions.ko.md).

## 거는 법

```sh
./build/global-shader shaders/crt/crt.frag                # 한 장 건다
./build/global-shader shaders/water/still.frag shaders/print/paper.frag
                                                          # 순서대로 겹쳐 건다
./build/global-shader --profile golden-era                # 저장해 둔 한 벌로
./build/global-shader --set CURVE 0.22                    # 값을 실시간으로 민다
./build/global-shader --check shaders/water/still.frag    # 번역만 — 창도
                                                          # 권한도 없이
```

이미 돌고 있으면 위 명령들은 두 번째를 안 띄우고 돌고 있는 쪽을 바꾼다. 끝내는
길은 `◲` → 끝내기, `--stop`, 또는 SIGINT/SIGTERM.

옵션 전부는 `--help` 에 있다. 영어와 한국어로 나온다 —
[다국어](docs/i18n.ko.md) 참고.

## 무엇을 치르나

화면을 계속 찍어서 도로 그리는 일이라, 부하가 **픽셀 수 × 프레임 수**에 비례한다 —
셰이더를 따지기 전에 이미 화면 크기를 따라 커진다. 배율이 걸린 화면 모드는 패널이
아니라 그보다 큰 *백킹* 해상도로 찍히고, 120Hz 패널은 60Hz 의 두 배를 요구하며,
셰이더가 없는 통과 상태에도 그 아래로는 안 내려가는 바닥이 있다.

노트북에서는 이것이 **배터리 소모와 발열**로 나타나고, 화면이 클수록 둘 다 커진다.
줄이는 손잡이는 이렇다:

```sh
--scale 0.7      픽셀을 줄인다 — 제곱으로 주므로 0.7 이면 절반쯤이다
--fps 30         프레임을 줄인다
--redraw never   화면이 안 바뀌면 안 그린다
```

셰이더의 `!motion` 손잡이는 반대편에서 같은 일을 한다. 0 으로 두면 계속 그리기가
저절로 꺼진다. `time` 을 아예 안 읽는 셰이더(`paper.frag`, `glow.glsl`)는 애초에
정지 화면에서 비용이 0 이다.

**프레임 비용은 쟀지만 전력과 온도는 안 쟀다.** 그리고
[대가](docs/performance.ko.md) 의 숫자는 60Hz MacBook Air M2 한 대에서 나온 것이라,
당신 기계에 대해서는 아무것도 말해 주지 않는다.

## 셰이더

```
shaders/
├── crt/          crt.frag  glow.glsl
├── water/        still.frag  river.frag  ocean.frag
├── cyberpunk/    neon.frag  glitch.frag
└── print/        paper.frag
```

하이프랜드 규약과 셰이더토이 규약을 둘 다 자동으로 알아보므로 어느 쪽 파일이든
그대로 넣으면 된다. `@min..max` 주석이 붙은 `#define` 은 실시간 슬라이더가 된다.
각 갈래가 무엇이고 값이 왜 그 값인지는 [셰이더](docs/shaders.ko.md) 에 있다.

## 문서

| | |
|---|---|
| [구조](docs/architecture.ko.md) | 왜 화면을 찍는 길밖에 없는가, 프레임이 지나는 길, 유일한 치명적 실패, GLSL → MSL, 셰이더 규약 둘 |
| [쓰는 법](docs/usage.ko.md) | 체인, 메뉴 막대, 설정과 프로필, 로그인할 때 시작, 제어 소켓, 옵션 전부 |
| [손잡이와 재그리기](docs/knobs.ko.md) | 돌아가는 중에 끄는 셰이더 값, `!motion`, 재그리기를 정하는 방식 |
| [셰이더](docs/shaders.ko.md) | 각 갈래가 무엇이고 왜 그런가 — 지운 셋까지 |
| [성능과 아직 안 한 것](docs/performance.ko.md) | 실제로 잰 값, 그리고 안 잰 것 |
| [홈브루로 설치하기](docs/install.ko.md) | 탭, 무엇이 어디에 놓이는지, 왜 cask 가 아닌지 |
| [화면 기록 권한](docs/permissions.ko.md) | 재빌드하면 조용히 끊기는 함정 |
| [다국어](docs/i18n.ko.md) | 영어와 한국어, 그리고 일부러 안 옮기는 것 |
| [라이선스와 먼저 있던 것들](docs/provenance.ko.md) | 셰이더 출처와 비슷한 물건들 |

[`CONTRIBUTING.md`](CONTRIBUTING.md) 에 셰이더 더하는 법, 번역 더하는 법, 그리고
안 받는 것이 있다. [`plan/`](plan/README.md) 은 이 레포를 공개하기까지의 작업
목록이고, 공증된 배포판에 아직 무엇이 남았는지도 거기 있다.

## 라이선스

MIT — [LICENSE](LICENSE). 브라운관 계열은 파생 저작물이고 물 셋은 착상 하나를
빌려 왔다. 둘 다 [라이선스와 먼저 있던 것들](docs/provenance.ko.md) 에 적어 뒀다.
