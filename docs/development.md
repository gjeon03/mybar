# 개발 가이드

## 요구 사항

Xcode 16 이상(Swift 6). macOS 14+ 대상, macOS 26에서 개발·검증.

## 자주 쓰는 명령

```bash
swift test                          # MyBarCore 단위 테스트
swift format lint -r Sources Tests  # 린트 (.swift-format, 2칸 들여쓰기)
swift format format -i -r Sources Tests
scripts/build-app.sh [debug|release]  # build/MyBar.app
scripts/install.sh                  # release 빌드 → /Applications 설치 → 실행
scripts/package.sh ~/Downloads      # 유니버설 앱 + 공유용 DMG
swift scripts/make-icon.swift       # 앱 아이콘 다시 그리기 (build/AppIcon-preview.png 미리보기)
tools/build.sh                      # 개발 도구를 build/tools 에 빌드
```

커밋 전: 포맷 → 린트 → 테스트 → 빌드.

## 권한과 실행 방식

- 터미널에서 `build/MyBar.app/Contents/MacOS/MyBar`를 직접 실행하면 **터미널의 권한**(손쉬운
  사용, 화면 기록)을 물려받습니다. 개발 중에는 이 방법이 편합니다.
- `/Applications`에 설치한 앱은 자기 권한이 필요하고, 애드혹 서명이면 재설치 때마다 다시
  허용해야 할 수 있습니다(→ macos26.md "권한").
- 서명은 `MYBAR_SIGN_IDENTITY` → 키체인의 "Developer ID Application" 인증서 → 애드혹 순으로
  고릅니다(`scripts/signing.sh`). 인증서로 서명하면 재설치해도 권한이 유지됩니다(→ releasing.md).
- 권한이 꼬이면: `tccutil reset Accessibility dev.gimbap.mybar; tccutil reset ScreenCapture dev.gimbap.mybar`
  또는 앱의 Permissions › Reset Permissions….

## 디버그 환경 변수 (디버그 빌드 전용)

| 변수 | 효과 |
|---|---|
| `MYBAR_SINGLE_DISPLAY=1` | 다른 디스플레이로 전환하는 대체 경로 끔(노트북 단독 흉내, macOS 26) |
| `MYBAR_NO_CONCEAL=1` | macOS 27 숨김(assertion)을 켜지 않음 |
| `MYBAR_DEBUG_STRIP=<경로>` | 사진 촬영 때 캡처한 메뉴바 띠를 PNG로 저장 |
| `MYBAR_DEBUG_OUT=<경로>` | 디버그 명령 결과 JSON 위치 |

macOS 27에서는 디버그 빌드를 `/Applications/MyBar.app`에 복사해 그 바이너리를 터미널에서 실행하세요
(→ macos27.md, build 폴더 사본은 자기 아이콘이 숨겨짐). `tools/axextras`는 모든 앱의 메뉴바
Accessibility 요소를 보여 줍니다.

## 로그

```bash
log stream --level debug --predicate 'subsystem == "dev.gimbap.mybar"'
```

카테고리: `app`, `scan`, `move`, `perf`. `perf`는 `Stopwatch` 구간 시간
(예: `activate scan / moves / pressed / done`, `move begin editing / moved one`,
`drag dragged / settled`). 릴리스 빌드에서는 키가 `<private>`로 가려집니다.

## 디버그 빌드 원격 명령

디버그 빌드(`scripts/build-app.sh debug`)는 분산 알림 `dev.gimbap.mybar.debug`로 명령을 받고 결과를
JSON으로 `MYBAR_DEBUG_OUT`(기본 `/tmp/mybar-debug.json`)에 씁니다. `tools/mybarctl`로 보냅니다.

| 명령 | 동작 |
|---|---|
| `dump` | 구역별 아이템·구분선 스냅샷 |
| `move <visible\|hidden\|alwaysHidden> <key>...` | 아이템 이동 |
| `reveal` | ‹ 클릭과 같음 |
| `activate <key>` | 바에서 누른 것처럼 열기 |
| `level <0\|1\|2>` | 펼침 단계 고정(none/hidden/all) |
| `group <이름> <key>...`, `ungroup <이름>` | 그룹 |
| `style <bar\|menuBar>` | 표시 방식 |
| `settings <tab>` | 설정 창 열기 |
| `diagnostics` | 진단 보고서를 클립보드로(설정 → Permissions → Copy Diagnostics와 같음) |

키 형식: `번들ID/식별자`, 예: `com.kakao.KakaoTalkMac/Item-0`,
`com.apple.controlcenter/com.apple.menuextra.wifi`.

## 실사용 시나리오 테스트 (중요)

단위 테스트로는 메뉴바 동작을 검증할 수 없습니다. **사용자가 하는 그대로** 테스트하세요.
이 프로젝트에서 실제로 문제를 찾은 건 전부 이 방식이었습니다.

`tools/` (빌드: `tools/build.sh`, 결과 `build/tools/*`):

| 도구 | 용도 |
|---|---|
| `cycle <회수> [대기ms]` | 실제 클릭으로 ‹ → 바의 임의 앱 → 메뉴가 뜰 때까지 대기 → 반복. 회차별 "SHOWN after N ms" / "NOTHING SHOWN" / "BAR DID NOT OPEN" 출력 |
| `curwatch <초>` | 4ms마다 실제 커서 표시 여부·위치, 커서 대역 창 위치 기록. "상단에 커서가 보임", "커서가 아예 없음" 찾기 |
| `jiggle <초>` | 사람이 마우스에 손을 얹은 것처럼 15ms마다 1pt씩 움직임(동시 실행해 간섭 테스트) |
| `modstate` | ⌘ 키가 눌린 상태로 남았는지 확인 |
| `release-command` | 남은 ⌘ 해제 |
| `axpress <번들ID>` | 그 앱 상태 아이템을 AX로 누름(합성 클릭과 비교용) |
| `pace <창ID> <x> <hover> <hold> <steps> <step> <release> <after>` | 드래그 속도 실험 |
| `statuswins` | 상태 아이템 창 프레임·그려짐 여부 |
| `mybarctl <명령>` | 디버그 명령 전송 |

예: 커서 이상 + 연속 실행 + 손 간섭을 한 번에

```bash
build/tools/curwatch 60 > /tmp/cw.txt &
build/tools/jiggle 60 &
build/tools/cycle 14 300
```

주의:
- 테스트는 사용자의 실제 화면·마우스를 씁니다. 사용 중이면 미리 알리고 짧게.
- 스크린샷은 **메뉴바 띠(높이 38pt)만** 찍으세요(`screencapture -x -C -R x,0,w,38`).
  아래쪽에는 작업 중인 내용이 있습니다. 클립보드 기록 앱처럼 개인 정보를 보여 주는 아이템은 열지 마세요.
- 화면이 잠겨 있으면(`CGSSessionScreenIsLocked`) 드래그가 동작하지 않습니다.

## 코드 규칙 요약

- 2칸 들여쓰기, `swift-format` 설정 준수, 주석은 영어. 커밋은 `type: 설명`(feat, fix, docs, refactor, test, chore, perf).
- 주변 코드의 주석 밀도·이름 짓기를 따름. 주석은 "왜"를 설명.
- 사람 입력이나 커서를 막는 코드는 반드시 워치독과 함께.
