# 구조

## 타깃

- **MyBarCore** (`Sources/MyBarCore`): AppKit에 의존하지 않는 순수 로직. 모두 단위 테스트
  (`Tests/MyBarCoreTests`) 대상.
  - `MenuBarItem.swift` — `WindowInfo`(창 서버 정보), `AXItemInfo`(접근성 정보, 소유 앱),
    `ItemKey`(`번들ID/식별자[#n]`, 설정에 저장되는 안정 키), `MenuBarItem`.
  - `ItemMatcher` — 상태 아이템 창과 AX 요소를 가로 위치로 짝지음. 지금 짝이 없으면 창 ID로
    기억해 둔 소유자(`remembered`)를 씀.
  - `MenuBarLayout` — 구역(Visible / Hidden / Always Hidden) 판정, 구분선 드롭 지점,
    `MenuBarGeometry`(화면 범위·노치·`notchClearance`·`isReachable`).
  - `ReachPlanner` — 노치 때문에 집을 수 없는 아이템을 끌어오는 "슬라이딩" 계획.
  - `DisplayMapping` — 여러 디스플레이에서 AX 좌표와 창 좌표를 오른쪽 끝 기준으로 변환.
  - `GlyphPixels` — 캡처한 아이콘이 단색 글리프인지 분석(템플릿 이미지 변환용).
  - `Settings` — `MyBarSettings`, `ItemGroup`, `RevealStyle`(bar / menuBar).
- **MyBar** (`Sources/MyBar`): 앱.

## 앱 구성 요소 (`Sources/MyBar`)

| 파일 | 역할 |
|---|---|
| `main.swift` | `AppDelegate`, 앱 시작 |
| `AppModel.swift` | 중심 상태·조정자. 스캔 갱신, 바 표시, 아이템 열기(`activate`), 그룹, 권한 폴링, 캡처 패스 |
| `StatusItems.swift` | MyBar 자신의 상태 아이템: 컨트롤(‹), Hidden 구분선, Always Hidden 구분선. `setLevel(_, for: source)`로 펼침 단계를 출처별로 요청 |
| `MenuBarScanner.swift` | 상태 아이템 창 목록 + AX 스캔 → `MenuBarSnapshot`(아이템, 구분선, 활성 디스플레이). `withCurrentFrames()`는 창 서버 좌표만 빠르게 갱신. `OwnerMemory`(창 ID→소유자, UserDefaults 저장), `ExtrasCache`(상태 아이템이 없는 앱 PID 캐시) |
| `ItemMover.swift` | ⌘-드래그로 아이템을 구역 사이로 이동. 덮개·입력 보호·커서 대역을 세우고, 필요한 만큼만 펼치고(`expand`), 드래그 후 정착(`settle`)을 확인. 노치 뒤 아이템은 `bringIntoReach`로 슬라이딩 |
| `ItemActivator.swift` | 바에서 누른 아이템 열기(임시 노출)와 복귀. 직렬 큐(`serially`), `generation`으로 낡은 복귀 취소, 복귀 대기 목록은 UserDefaults `MyBarTemporarilyShown`에 저장 |
| `EventDriver.swift` | 마우스 이벤트 합성(드래그·클릭). 속도 프로필 `DragPace`(standard/quick/swift/slide), 클릭 카운트 1, 드래그 후 ⌘ 해제, 커서 원위치 확인, "지금 MyBar가 커서를 몰고 있는지" 상태 |
| `InputShield.swift` | 이벤트 탭. MyBar가 일하는 동안 사람의 클릭을 잠시 보류(끝나면 바/아이콘 클릭은 재실행), 드래그 중에만 마우스 이동 보류. 최대 5초 워치독 |
| `MenuBarCurtain.swift` | 모든 디스플레이 메뉴바를 직전 스크린샷으로 덮어 재배치를 숨김(ScreenCaptureKit). 바가 열려 있는 동안 1초마다 미리 캡처. 최대 6초 워치독 |
| `CursorStandIn.swift` | 진짜 커서를 숨기고 그 자리에 커서 그림을 띄움(드래그 사이에는 마우스를 따라감). `Cursor`는 백그라운드 커서 숨김/표시와 재숨김. 최대 6초 워치독 |
| `BarPanel.swift` | 메뉴바 아래 뜨는 바(숨긴 아이템 그림 목록) |
| `ItemImages.swift` | 아이템 그림 캡처·디스크 캐시(`~/Library/Application Support/MyBar/ItemImages`) |
| `GroupItems.swift` | 그룹용 상태 아이템 |
| `SettingsView.swift` | 설정 창(Layout / Groups / General / Permissions). General에 아이콘 선택(`IconPicker`) |
| `ControlIconRenderer.swift` | MyBar 아이콘 그리기(`ControlIcon`: 내장 스타일·SF Symbol·사용자 그림), 사용자 그림 보관(`CustomIconStore`) |
| `Concealer.swift`, `AgentScanner.swift` | macOS 27 전용: 허용 목록 숨김·Control Center 모듈 숨김, AX 기반 스캔(→ macos27.md) |
| `SystemServices.swift` | 단축키, 로그인 시 실행, 권한 확인·요청 |
| `Support.swift` | 로그(`Log.*`, 성능은 `perf` 카테고리), `Stopwatch`, `OwnItemName`, `MenuState`(메뉴·팝오버 열림 감지) |
| `DebugControl.swift` | 디버그 빌드 전용 원격 명령(→ development.md) |

## 숨김 원리

MyBar는 상태 아이템 세 개를 둡니다(오른쪽에서 왼쪽 순):

```
[Always Hidden 구분선][Always Hidden 아이템…][Hidden 구분선][Hidden 아이템…][컨트롤 ‹][Visible 아이템…]
```

구분선은 접히면 길이 10,000(시스템이 약 5,000pt로 제한)으로 늘어나 왼쪽의 아이템을 모두
화면 밖(음수 x)으로 밀어냅니다. 펼칠 때는 구분선을 짧게 합니다. 펼침 단계(`RevealLevel`)는
none / hidden / all이고 출처별 요청(`edit`, `capture`, 사용자 등)의 최댓값이 적용됩니다.

## 아이템 열기(임시 노출) 흐름

`AppModel.activate` → `ItemActivator.activate` → 직렬 큐 → `performActivation`:

1. 권한이 없으면 이동을 시도하지 않고 권한 화면을 엽니다.
2. 진행 중인 아이콘 캡처 패스를 취소하고 끝나기를 기다립니다(둘 다 메뉴바를 펼치므로 충돌).
3. 입력 보호(`InputShield`)와 커서 대역(`CursorStandIn`)을 올립니다.
4. 바가 가진 스냅샷(`known`)을 창 서버 좌표로 갱신해 기준으로 삼고, 대상이 Visible이 아니면
   덮개(`MenuBarCurtain`)를 올립니다.
5. 이전에 꺼낸 아이템이 2개 이상 남아 있으면 먼저 되돌리고, 대상을 Visible로 옮깁니다
   (`ItemMover.perform`, 한 세션).
   - `perform`: 덮개 → 기준 스냅샷 → `expand(.hidden)`(Always Hidden이 관련될 때만 `.all`)
     → 이동 → `endEditing`.
   - 대상이 노치 뒤에 있으면 `bringIntoReach`로 슬라이딩(아래).
6. 덮개를 유지한 채 아이템을 클릭(이동 실패 시 AX Press로 대체). 그 즉시 입력 보호와 커서
   대역을 내리고, 메뉴바가 접힌 뒤 덮개를 내립니다.
7. `scheduleRestore`: 메뉴/팝오버가 `activationShowDuration`(기본 5초) 동안 닫혀 있으면
   대기 목록을 한 번에 되돌립니다. 바가 열려 있는 동안은 미룹니다(`holdsReturns`).
   앱이 그 사이 종료되면 다음 실행 1.5초 후 `restoreAfterLaunch`로 되돌립니다.

## 슬라이딩 (노치)

노치 뒤·왼쪽(그리고 노치 오른쪽 약 20pt) 아이템은 그려지지 않아 집을 수 없습니다. 하지만
드래그한 아이템은 그려지지 않는 곳 위에도 **놓을 수는** 있습니다. 그래서 대상 오른쪽의 그려진
같은 구역 아이템을 대상 바로 왼쪽에 하나씩 떨어뜨리면 대상이 그 폭만큼 오른쪽으로 밀려
결국 집을 수 있게 됩니다(`ReachPlanner`).

- 옮길 아이템: 아이콘 크기(≤52pt) 중 부족분을 덮는 가장 좁은 것, 없으면 가장 넓은 것.
- 드롭 지점: `target.minX + carried + 3` — 들어 올리면 왼쪽 아이템들이 그 폭만큼 오른쪽으로
  당겨지므로, 이동한 대상의 왼쪽 가장자리 안쪽. 대상 원래 위치보다 왼쪽으로는 절대 안 감.
- 안전장치: 전체 3.5초 예산, 진전 없으면 그 후보 제외, 3회 무진전이면 포기, 슬라이딩 중
  구역이 바뀐 아이템은 즉시 되돌림.
- 되돌린 아이템은 Hidden의 가장 오른쪽(구분선 옆)으로 가므로 자주 쓰는 아이템일수록 빨라짐.

## 동시성 원칙

- 아이템 열기·복귀는 `ItemActivator.serially`로 한 번에 하나씩.
- 덮개·입력 보호·커서 대역은 깊이(depth)로 중첩되며 각각 워치독이 있음. 사람의 입력이나
  커서를 막는 장치는 **반드시** 시간 제한이 있어야 함(과거 20초간 커서가 사라진 사고).
- 스캔은 백그라운드(`Task.detached`), UI·상태는 MainActor.
