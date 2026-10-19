# macOS 27 (Golden Gate) 메뉴바와 MyBar

macOS 27에서 메뉴바 구조가 근본적으로 바뀌어 macOS 26용 방식이 전혀 동작하지 않습니다. 이 문서는
macOS 27.0.1(26A434)에서 실측한 사실과 MyBar의 macOS 27 설계를 정리합니다.

## 무엇이 바뀌었나 (실측)

| | macOS 26 | macOS 27 |
|---|---|---|
| 상태 아이템 | 아이템마다 Control Center 소유 창(레이어 25) | **창 없음**. `MenuBarAgent`(새 시스템 프로세스)가 메뉴바 전체를 그림 |
| 아이템 위치 | 창 목록(`CGWindowList`) | Accessibility(`AXExtrasMenuBar`)만 |
| 공간 부족 | 노치 뒤에 가려짐 | 왼쪽부터 접혀 시스템 `«`("Show Hidden Menu Bar Items") 뒤로 |
| 긴 구분선(10,000pt) | 왼쪽 아이템을 화면 밖으로 밀어냄 | 무시됨(레이아웃에서 빠짐) → **MyBar 26 방식 숨김 불가** |
| Apple 아이템 | Control Center 소유 창 | MenuBarAgent의 그룹 요소 안에 Control Center의 요소(식별자 `com.apple.menuextra.*` 유지) |

## 시도했다가 버린 방법

1. **스페이서**: 남은 공간보다 살짝 넓은 상태 아이템을 두면 시스템이 그것과 그 왼쪽을 `«` 뒤로
   접는다(실측: 120–800pt는 접힘, 1,800pt 이상은 무시). 동작은 했지만 `«`가 항상 보임.
2. **`«` 덮개**: 메뉴바 배경 조각을 덮어 가리기. 메뉴바가 반투명이라 색이 미묘하게 어긋남.

`«`가 항상 보이는 것은 받아들일 수 없어 허용 목록 방식으로 전환.

## 아이템 감추기: 허용 목록(assessment mode)

macOS 27에는 시험 응시 앱 등을 위한 "평가 모드" 인터페이스가 비공개 프레임워크 `MenuBarClientCore`에 있다.
`MBAssessmentModeConfiguration(allowedSystemItems:allowedBundleIdentifiers:)`로 구성한
`MBAssessmentModeAssertion`을 활성화하면 **허용 목록에 없는 앱의 메뉴바 아이템이 완전히 사라진다**
(접힘·`«`·빈칸 없음). MyBar는 허용 목록 = 실행 중인 모든 앱 − 숨길 앱으로 구성한다. 임시 표시는 숨긴 앱을
잠깐 허용 목록에 넣어 제자리에 나타나게 한 뒤 누르는 방식이다.

## 직접 측정한 규칙 (MyBar가 의존하는 것)

- 일반 앱도 이 assertion을 활성화할 수 있다(권한·엔타이틀먼트 불필요, 오류 없음).
- **한 assertion은 허용 범위를 넓히는 갱신만 반영된다.** 더 좁히려면 새 assertion을 활성화하고
  **그다음** 이전 것을 `invalidate`. 살아 있는 assertion이 여럿이면 가장 관대한 것이 적용된다.
  이전 것을 먼저 없애고 새로 만드는 순서는 실패했다.
- **프로세스가 끝나면 시스템이 제한을 자동 해제** → 모든 아이템이 돌아옴(안전장치).
- 같은 프로세스 안에서 `invalidate`만으로는 즉시 풀리지 않을 수 있다 → 전부 보이려면 "모두 허용"
  구성을 새로 활성화.
- `systemItems` 번호 0 = 배터리. 1–8은 이 Mac에 없는 시스템 아이템으로 추정(변화 없음).
  Wi‑Fi·사운드 등은 이 목록과 무관(Control Center 설정 쪽).
- 숨긴 앱의 아이템은 Accessibility가 **마지막 위치를 그대로** 보고한다(숨김을 AX로 알 수 없음)
  → 숨김 상태는 MyBar가 직접 기억해야 한다(`concealedApps` 설정).
- 다시 허용하면 약 0.3초 안에 제자리에 나타나지만, 그 직후 AX 위치는 그려진 위치와 어긋날 수
  있고, 나타난 아이템은 강조(알약 모양 배경)되어 그려진다 → 이때 사진을 찍으면 안 된다.
- **허용 판단은 등록된 앱 위치 기준**으로 보인다: `build/` 폴더에서 실행한 디버그 빌드는 허용
  목록에 있어도 자기 아이콘이 숨겨졌고, `/Applications`에 설치된 사본은 정상. 개발 시
  `/Applications/MyBar.app`에 복사해 실행할 것.

## Apple 시스템 아이템 숨기기 (실측)

- Wi‑Fi·사운드·디스플레이·배터리 등은 Control Center 모듈이다. 메뉴바 표시 여부는 Control Center의
  **호스트별(ByHost) 환경설정** `com.apple.controlcenter`의 모듈 키(`WiFi`, `Sound`, `Display`,
  `Battery`, `FocusModes` …)에 있다. 값: `2` 보임, `18` 상황에 따라 보임, `8` 숨김(`24`는 AX의
  "Remove from Menu Bar" 동작 후).
- 이 값을 바꾸면(`CFPreferencesSetValue(..., kCFPreferencesCurrentHost)` + 동기화) Control Center가
  **즉시** 따른다. 일반 도메인의 `NSStatusItem VisibleCC <이름>`은 바꿔도 반영되지 않는다.
- 숨긴 모듈은 AX에서도 완전히 사라진다(앱 숨김과 달리 마지막 위치가 남지 않음) → MyBar는 숨긴 시스템
  아이템을 이름표만 가진 자리표시로 목록에 넣고, 열 때는 원래 값을 되돌려 다시 나타난 요소를 찾아 누른다.
- 이 환경설정은 MyBar가 끝나도 그대로 남으므로, 원래 값을 `MyBarSystemModuleOriginals`에 저장해 두고
  **정상 종료 시 되돌린다**(강제 종료 시에는 다음 실행 때 다시 적용되며 원래 값은 보존됨).
- 시계와 Control Center 아이콘은 숨길 수 없다(AX에 "Remove from Menu Bar"도 없음) → 설정에서 드래그
  불가, "Fixed by macOS" 표시.

## MyBar의 macOS 27 설계

| 기능 | 구현 |
|---|---|
| 모드 판별 | `MenuBarSystem.usesAgent` (MenuBarAgent 실행 여부) |
| 스캔 | `AgentScanner`: AX만으로 아이템 구성, 창 ID는 키 해시로 대체 |
| 숨김 | `Concealer`: `concealedApps`(번들 ID 또는 시스템 아이템 키 → Hidden/Always Hidden)를 저장. 앱은 허용 목록 = 실행 중인 앱 − 숨긴 앱, Apple 시스템 아이템은 Control Center 환경설정 값. 앱 실행/종료 때 다시 적용 |
| 구역 | 위치가 아니라 `concealedApps`로 결정(`MenuBarSnapshot.concealed`) |
| 바에서 열기 | 이전에 연 것 숨김 → 대상 앱만 허용 → 나타나면 AX Press → 메뉴가 닫히고 `activationShowDuration` 뒤 다시 숨김 |
| 설정에서 구역 이동 | 숨김 목록 변경만(드래그 없음). 숨기기 직전 아이템 사진 촬영 |
| "메뉴바에 표시" 방식 | 전부 허용(`revealAll`) |
| 사진 | 시작 시(제한 적용 전) 숨김 아이템 촬영, 숨기기 직전 촬영. 화면에서 잘라내 배경을 빼고 글리프만(`GlyphPixels.lift`). 실패 시 앱 아이콘 |
| 구분선 | 쓰지 않음(길이 0) |

## 알려진 한계

- 숨김은 **앱 단위**(한 앱의 여러 아이템을 나눌 수 없음).
- 시계·Control Center 아이콘은 숨길 수 없음(macOS 제약).
- 시스템 아이템 숨김은 Control Center 환경설정을 바꾸는 방식이라, MyBar가 강제 종료되면 숨긴 채로 남는다
  (다음 실행 또는 시스템 설정 › 메뉴 막대에서 복구).
- 비공개 API라 macOS 업데이트로 바뀔 수 있다.
- 메뉴바가 꽉 차면 시스템 `«`가 다시 나타날 수 있다(자동 넘침 숨김은 미구현).
- 숨긴 앱의 메뉴바 글리프 사진은 화면이 정리된 순간에만 찍을 수 있어, 없으면 앱 아이콘으로 표시.
