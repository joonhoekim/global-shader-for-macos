# 라이선스와 먼저 있던 것들

*[← README](../README.ko.md)  ·  [English](provenance.md)*

## 라이선스와 출처

MIT. 자세한 건 [LICENSE](../LICENSE).

`shaders/` 는 갈래가 둘이다.

**새로 짠 것** — 물 셋(`water/*.frag`), 사이버펑크 둘(`neon.frag` ·
`glitch.frag`), 인쇄 하나(`paper.frag`). 아래 브라운관 계열과 코드를 공유하지
않는다.

이 여섯 장은 잘 알려진 기법을 각자 다시 구현한 것이다 — 골든앵글 나선 블룸,
값 노이즈와 그 해석적 도함수 같은 것들은 특정 저작물이 아니라 그래픽스의 공유
재산이고, 어디서 왔는지가 중요한 자리에는 파일 머리말에 적어 뒀다. 옮겨온
코드는 없다. (지운 `rain.frag` · `riso.frag` · `dither.frag` 도 같은 자리에
있었다 — Bayer 순서 디더와 CMYK 회전 망점이 그쪽이었다.)

한 군데만 따로 적는다. 물 셋의 **글자 지키기**는
[xatuke/screenshader](https://github.com/xatuke/screenshader) 의
`underwater.frag`(MIT) 에서 착상을 얻었다 — 거기서 "화면 전체에 거는 물은
글자를 어떻게 해야 하는가"라는 문제 자체를 봤다. 방식은 다르고([셰이더](shaders.ko.md) 의 「물 셋」)
수식은 옮겨오지 않았다.

**브라운관 계열(`crt.frag`, `glow.glsl`)은 파생 저작물이다.**
space_dots(Golden Era) 라이스 — vdawg 의 chezmoi 닷파일, `.other/hyprshaders/orig.frag` —
에 들어 있던 **Maxim Samoliuk 의 Hyprland 화면 셰이더(MIT, Copyright 2023)** 가
뿌리다.

한 줄씩 대조해서 실제로 살아남은 것은 둘이다. `curve()` 의 통 왜곡 식(원본은
성분별로 썼고 여기서는 벡터로 접었다, `1/8` → `0.10`)과 `bezel()` 의
`uv * (1.0 - uv.yx)` 비네트 관용구(같은 식, 다른 상수). 나머지는 다시 짰다 —
블룸(임계값 없는 균등 극좌표 이중루프에서, 가우시안 가중과 소프트 니 휘도
임계를 쓰는 황금각 나선 16탭으로), 그레인, 스캔라인, 색수차, 어퍼처 그릴,
해시 함수. 원본의 깜빡임·감마 축소·인광체 틴트는 아예 뺐다. `glow.glsl` 은
원본과 공유하는 줄이 하나도 없고 `crt.frag` 를 통해 내려온다. 무엇을 왜
바꿨는지는 `crt.frag` 머리말에 있다.

살아남은 둘 다 원본보다 먼저 있던 셰이더토이 CRT 관용구라, 라이선스가 엄밀히
요구하는 것보다 더 적는 쪽일 것이다. 그래도 적는 이유는 경로가 실제로 있고
저자가 그걸 알기 때문이다 — 독립적으로 다시 발명한 것이 아니다. 셰이더 자체의
정본 URL 은 처음 옮겨올 때 기록되지 않아서 이름으로만 적어 둔다.

## 먼저 있던 것들

같은 구조를 쓰는 것이 이미 있다 — [xatuke/screenshader](https://github.com/xatuke/screenshader)
(Swift + SCK + Metal, GLSL→MSL 자동 변환), [RetroVisor](https://dirkwhoffmann.github.io/RetroVisor/)
(화면 전체가 아니라 옮길 수 있는 창 하나). 이 레포가 따로 있는 이유는 하이프랜드
규약(`pointer_pressed_*` 까지)을 그대로 받아서 같은 `.frag` 파일을 두 OS 에서
쓰려는 것이다.
