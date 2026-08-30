# 홈브루로 설치하기

*[← README](../README.ko.md)  ·  [English](install.md)*

```sh
brew tap joonhoekim/global-shader https://github.com/joonhoekim/global-shader-for-macos
brew install joonhoekim/global-shader/global-shader
open "$(brew --prefix global-shader)/GlobalShader.app"
```

주소를 따로 적는 이유는, `brew tap user/name` 만 쓰면 홈브루가
`homebrew-name` 이라는 저장소를 찾기 때문이다. 이 저장소 이름은 홈브루가 아니라
내용물을 따라 지었으니 탭에 주소를 알려 준다. 그 뒤는 다르지 않다.
`brew upgrade global-shader`, `brew uninstall global-shader` 는 짧은 이름으로 된다.

## 왜 cask 가 아니라 formula 인가

맥 앱은 보통 cask 로 설치하는데, 여기서는 그 길만 아직 막혀 있다.

cask 는 다 만들어진 `.app` 을 내려받고, 홈브루는 내려받은 것에 격리(quarantine)
표시를 단다. 그러면 Gatekeeper 가 공증을 요구하고, 공증은 유료 Apple Developer
계정을 요구하는데 그 계정이 없다 — [`plan/`](../plan/README.md) 전체가 이 전제
위에 쓰여 있다. 자체 서명으로는 대신할 수 없다. 애플이 그 인증서를 보증한다는
사실 자체가 검사의 내용 전부이기 때문이다.

formula 는 설치하는 기계에서 컴파일한다. 앱을 내려받는 일이 없으니 격리될 것도
없고, 그 기계가 스스로 빌드한 바이너리에 대해 Gatekeeper 는 할 말이 없다. 비용이
사라진 것은 아니고 자리를 옮겼을 뿐이다 — 아래
[업그레이드하면 화면 기록 권한이 풀린다](#업그레이드하면-화면-기록-권한이-풀린다)
가 그 자리다.

빌드는 직접 클론했을 때와 같은 `./build.sh` 다. `swiftc`, 번들 묶기, 임의 서명.
`glslang` 과 `spirv-cross` 는 홈브루 의존성으로 들어가니 알아서 깔린다.

## 무엇이 어디에 놓이는가

| | |
|---|---|
| `$(brew --prefix global-shader)/GlobalShader.app` | 앱 — 화면 기록 권한을 쥐는 쪽 |
| `$(brew --prefix)/bin/global-shader` | 명령줄. 번들 안을 가리키는 심링크 |
| `$(brew --prefix global-shader)/share/global-shader/shaders` | 같이 딸려 오는 셰이더 |
| `$(brew --prefix global-shader)/libexec/make-signing-cert.sh` | 인증서 스크립트. 아래 절에서 쓴다 |

formula 는 `/Applications` 에 무엇을 놓을 수 없다 — 그건 cask 의 일이다 — 그래서
앱은 prefix 안에 있다. Finder 와 Spotlight 에서 찾으려면:

```sh
ln -sfn "$(brew --prefix global-shader)/GlobalShader.app" /Applications/GlobalShader.app
```

띄울 때는 명령줄이 아니라 번들에서 띄운다. 맨 바이너리는 자기를 띄운 쪽 —
그러니까 터미널 — 의 화면 기록 권한을 빌려 쓰고, 번들은 자기 이름으로 허가를
받는다. 이유는 [화면 기록 권한](permissions.ko.md) 에 있다. 일단 떠 있으면
`global-shader` 명령은 제어 소켓으로 말을 걸 뿐이라 따로 권한이 필요 없다.

```sh
open "$(brew --prefix global-shader)/GlobalShader.app"
global-shader "$(brew --prefix global-shader)/share/global-shader/shaders/crt/crt.frag"
global-shader --set CURVE 0.22
global-shader --stop
```

## 업그레이드하면 화면 기록 권한이 풀린다

formula 로 가는 값이고, 겪기 전에 알아 두는 편이 낫다.

설치할 때마다 앱을 새로 빌드하고, 그 빌드는 임의 서명이라 지정 요구사항이 맨
`cdhash` 하나다. TCC 는 권한을 줄 때 그 cdhash 를 저장해 두고 맞춰 본다. 새 빌드는
새 해시이니 허가가 더 이상 붙지 않는데, **macOS 는 다시 묻지 않는다.** 시스템
설정의 체크박스는 켜진 채로 남고 캡처만 조용히 멈춘다.
`brew upgrade global-shader` 뒤에는 매번:

```sh
tccutil reset ScreenCapture dev.jh.global-shader
open "$(brew --prefix global-shader)/GlobalShader.app"     # 다시 물어본다 → 허용
```

### 인증서로는 안에서 해결되지 않는다

클론해서 쓰면 자리를 지키는 인증서로 서명해서 이걸 피한다
([화면 기록 권한](permissions.ko.md)). 홈브루를 거치면 그 길이 막혀 있는데, "인증서를
먼저 만들면 되지 않나"가 되기 쉬우니 이유를 적어 둔다.

| | |
|---|---|
| 빌드의 `HOME` 이 임시 디렉터리다 | 홈브루는 빌드 디렉터리 안의 `.brew_home` 을 `HOME` 으로 준다. 키체인 검색 목록은 `HOME` 에서 읽으므로 `security` 에는 시스템 키체인만 보인다 — 로그인 키체인도, 신원도 없다 |
| 샌드박스가 `~/Library/Keychains` 를 막는다 | 키체인 경로를 직접 대도 안 된다. 홈브루 빌드 샌드박스에는 그 경로를 읽지 못하게 하는 규칙이 `.ssh`, `.gnupg` 같은 것들과 함께 들어 있다 |
| 끄는 방법이 없다 | `HOMEBREW_NO_SANDBOX` 는 없어졌다. brew 6 기준으로 끌 수 있는 것은 리눅스와 cask 쪽뿐이고, formula 빌드는 언제나 샌드박스 안이다 |

싸울 가치가 있는 문제는 아니다. 막는 쪽이 옳다.

### 그러면 밖에서 직접 서명한다

샌드박스가 막는 것은 **빌드**가 키체인에 닿는 일이다. 내 셸은 그런 제약이 없고 설치된
번들은 쓸 수 있으니, 서명은 나중에 갈아 끼우면 된다. 신원은 한 번만 만든다:

```sh
"$(brew --prefix global-shader)/libexec/make-signing-cert.sh"
```

그리고 업그레이드할 때마다:

```sh
codesign --force --sign "jh local codesign" "$(brew --prefix global-shader)/GlobalShader.app"
```

요구사항이 `identifier "dev.jh.global-shader" and certificate leaf H"…"` 가 되는데,
인증서가 그대로이니 이 값은 매번 같다. TCC 는 계속 맞다고 보고, 그래서 권한이
살아남고 아무것도 묻지 않는다. 클론해서 빌드했을 때와 똑같은 서명이고, 붙는 시점만
다르다.

손으로 다시 서명하는 것조차 싫다면 클론해서 빌드하는 쪽이 낫다. 거기서는 `./build.sh`
가 알아서 인증서를 집어 쓰고, 업그레이드는 `git pull` 이면 된다.

## 아직 태그가 없는 동안

`v*` 태그가 아직 없어서 formula 에는 stable url 이 없고 `head` 만 있다. 홈브루는
이 경우를 안다. stable 이 없으면 `brew install` 이 `main` 에서 빌드한다.

다른 점은 업그레이드 하나다. `brew upgrade` 는 버전을 비교하는데 head 설치에는
비교할 버전이 없으니, 보라고 말해 줘야 한다:

```sh
brew upgrade --fetch-HEAD global-shader
```

태그가 생기면 [`tools/update-formula.sh`](../tools/update-formula.sh) 가 tarball
주소와 sha256 을 formula 에 써 넣고, 그때부터 그냥 `brew upgrade` 가 된다.

## 지우기

```sh
brew uninstall global-shader
brew untap joonhoekim/global-shader
rm -f /Applications/GlobalShader.app             # 심링크를 만들었다면
tccutil reset ScreenCapture dev.jh.global-shader
```

설정과 프로필은 홈브루 것이 아니라 그대로 남는다. `~/.config/global-shader/` 에
있다.

## Apple Developer 계정이 생기면 달라지는 것

cask 가 가능해진다. `tools/release.sh` 는 이미 zip 까지 만들어 놓고 서명 자리를
비워 두었고, 거기에 `codesign --options runtime` 과 `notarytool submit` 두 줄이
들어가면 끝이다. 그러면 cask 는 공증된 앱을 `/Applications` 에 넣고, 권한 주의사항도
없어진다. 공증된 서명은 판이 바뀌어도 그대로라 TCC 가 허가를 유지하기 때문이다.

그렇다고 formula 를 없앨 이유는 없다. 내려받은 것을 믿느니 소스에서 빌드하겠다는
사람에게는 이쪽이 길이고, 오늘 탭이 돌아가게 하는 것도 이쪽이다.
