# MyBar 개발 문서

MyBar는 macOS 메뉴바 아이템을 숨기고, 숨긴 아이템을 메뉴바 아래 바(Bar)에서 꺼내 쓰게 해 주는
앱입니다(그룹 기능 포함). 이 폴더는 코드를 고치기 전에 알아야 할 구조와, macOS 메뉴바에 대해
**직접 실측해서 확인한 사실**을 정리한 것입니다.

| 문서 | 내용 |
|---|---|
| [architecture.md](architecture.md) | 구성 요소와 주요 흐름(스캔 → 바 → 임시 노출 → 복귀), 파일별 책임 |
| [macos27.md](macos27.md) | **macOS 27(Golden Gate)** 메뉴바 변화와 MyBar의 27용 설계(허용 목록으로 숨김) |
| [macos26.md](macos26.md) | macOS 26 메뉴바에 대해 실측으로 확인한 사실과 함정. 26 경로를 고치기 전에 꼭 읽기 |
| [development.md](development.md) | 빌드·테스트·설치, 디버그 빌드 명령, 로그, 실사용 시나리오 테스트 도구 |
| [releasing.md](releasing.md) | 서명·공증·릴리스, 권한(TCC)이 켜져 있는데 안 되는 이유 |

## 한눈에 보기

- Swift Package(`Package.swift`), macOS 14+, Swift 6. 앱 타깃 `MyBar`, 순수 로직 라이브러리
  `MyBarCore`(단위 테스트 대상). 번들 ID `dev.gimbap.mybar`.
- 실행 중인 시스템에 따라 두 경로로 동작합니다(`MenuBarSystem.usesAgent`).
  - **macOS 26까지**: 아주 긴 구분선이 왼쪽 아이템을 화면 밖으로 밀어냄. 바에서 아이템을 누르면 실제
    아이템을 ⌘-드래그로 잠깐 보이는 구역으로 옮겨 클릭하고, 메뉴가 닫히면 되돌림. 노치 뒤 아이템은
    "슬라이딩"으로 끌어옴.
  - **macOS 27부터**: MenuBarAgent의 허용 목록(assessment mode)으로 앱 단위로 감추고, 누를 때 잠깐
    허용해 제자리에 나타나게 함. Wi‑Fi 같은 시스템 아이템은 Control Center 설정으로 숨김.
- 필수 권한: 손쉬운 사용(Accessibility), 화면 기록(Screen Recording). 권한은 앱 서명에 묶이므로
  배포 빌드는 Developer ID로 서명·공증(→ releasing.md).
