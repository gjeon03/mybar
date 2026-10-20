# 서명·공증·릴리스

## 처음 한 번 (릴리스하는 Mac)

1. Apple Developer Program 계정으로 **Developer ID Application** 인증서를 만든다.
   Xcode → Settings → Accounts → (팀) → Manage Certificates → + → Developer ID Application.
   `security find-identity -v -p codesigning`에 `Developer ID Application: …`이 보이면 된다.
   - `Unable to process request - PLA Update available`이 나오면 Apple이 프로그램 라이선스 계약을 갱신한
     것이다. developer.apple.com/account에서 동의한 뒤 다시 한다.
   - Accounts에 유료 팀이 안 보이면 Xcode가 예전 팀 목록을 들고 있는 것이다. Accounts를 열어 새로 고친다.
   - 인증서에는 만료일이 있다(2026-10에 만든 것은 2027-02-01). 만료 전에 새로 만들면 되고, 권한(TCC)은 팀 ID로
     묶여 있어 그대로 유지된다. 이미 서명·공증한 DMG는 만료 뒤에도 유효하다.
2. 공증용 자격 증명을 키체인에 저장한다(앱 암호는 account.apple.com → 로그인 및 보안 → 앱 암호에서 만든다).
   암호가 셸 기록에 남지 않도록 `--password`를 쓰지 말고 물어볼 때 입력한다.

   ```bash
   xcrun notarytool store-credentials mybar --apple-id <Apple ID> --team-id <팀 ID>
   ```

## 릴리스 전: macOS 26 확인

한 앱이 26과 27을 모두 지원한다(`MenuBarSystem.usesAgent`로 경로 선택). 26 경로는 1.4.0 때 26.6.2에서
확인했다(노치·외부 모니터는 해당 Mac이 없어 제외). 26 경로를 고쳤거나 새 26.x가 나오면 아래를 다시
확인한다. 26 경로의 원리와 함정은 macos26.md, 실사용 테스트 도구는 development.md.

1. `scripts/install.sh` → 권한 두 개 허용(손쉬운 사용, 화면 기록). 예전 번들 ID(`dev.mybar.MyBar`)의
   설정이 있는 Mac이면 그 설정이 넘어오는지(Layout 탭의 구역 배치·그룹) 확인.
2. 구분선 두 개(Hidden, Always Hidden)가 메뉴바에 생기고 접으면 왼쪽 아이템이 사라지는지.
3. 설정 Layout 탭에서 아이템을 Visible ↔ Hidden ↔ Always Hidden으로 옮기기, ⌘-드래그로 옮기기.
4. MyBar 아이콘 클릭 → 바에 숨긴 아이템 그림 → 하나 클릭 → 그 아이템만 메뉴바에 와서 열리고, 닫은 뒤
   몇 초 후 제자리로. `tools/cycle 10 300`으로 연속 실행(→ development.md).
5. 노치 화면이면 노치 뒤 아이템 열기(슬라이딩), 외부 모니터가 있으면 양쪽에서.
6. 그룹 아이콘, ⌥⌘B, 아이콘 스타일 변경, Permissions 탭(경고·Reset 버튼).
7. 종료하면 모든 아이템이 돌아오는지.

문제가 있으면 고치고, 통과하면 README의 Requirements(“macOS 26 … tested on …”)를 확인한 버전으로 고친 뒤 릴리스.

## 릴리스

```bash
# 1. Resources/Info.plist의 CFBundleShortVersionString, CFBundleVersion 올리기
swift format lint -r Sources Tests && swift test
MYBAR_NOTARY_PROFILE=mybar scripts/package.sh build   # 유니버설 앱 → 서명 → DMG → 공증 → 스테이플
gh release create v<버전> build/MyBar-<버전>.dmg --title "MyBar <버전>" --notes-file <노트 파일>
```

- `scripts/signing.sh`가 서명 인증서를 고른다: `MYBAR_SIGN_IDENTITY` → 키체인의 Developer ID
  Application → 애드혹(`-`). 무엇으로 서명됐는지는 스크립트 마지막 줄과 `codesign -dr - <앱>`으로 확인.
- 공증은 `MYBAR_NOTARY_PROFILE`이 있을 때만 하고, 끝나면 `spctl --assess`로 확인한다.
- `package.sh`는 아키텍처별로 빌드한 뒤 `lipo`로 합친다. `--arch`를 둘 다 주면 Xcode 16.3의 빌드 시스템이
  앱 타깃의 Swift 5 모드를 거부하고(`given: [5], supported: []`), 새 도구 체인은 아키텍처별 결과물을 같은
  폴더에 써서 서로 덮어쓰기 때문이다(빌드 직후 따로 복사해 둔다).
- 게시한 뒤에는 공개 URL에서 내려받아 SHA-256, `xcrun stapler validate`, `spctl --assess`로 한 번 더 확인한다.
- 웹사이트(`site/`)의 다운로드 버튼은 GitHub API로 최신 릴리스의 `.dmg`를 찾아 연결하므로 따로 고칠
  필요가 없다. 자산 이름은 `MyBar-<버전>.dmg`를 유지할 것.
- DMG 안의 안내문은 `Resources/READ-ME-FIRST.txt`.

## 권한이 켜져 있는데 안 되는 이유 (TCC)

증상: 시스템 설정에서 손쉬운 사용·화면 기록이 분명히 켜져 있는데 MyBar Permissions 탭은 빨간 X.

- macOS(TCC)는 권한을 **앱의 지정 요구 사항(designated requirement)**에 묶어 저장한다.
  `codesign -dr - /Applications/MyBar.app`으로 볼 수 있다.
  - 애드혹: `designated => cdhash H"…"` — **빌드마다 바뀌는 해시**. 새 버전은 다른 앱이다.
  - Developer ID: `identifier "dev.gimbap.mybar" and anchor apple generic and certificate leaf[subject.OU] = <팀 ID> …`
    — 같은 팀으로 서명하면 **버전이 바뀌어도 같다**.
- 그래서 애드혹 빌드에 준 권한 스위치는 "켜짐"으로 남아 있어도 새 빌드에는 적용되지 않는다. 껐다 켜도
  소용없고, 목록에서 **−로 지우거나** 초기화해야 한다.

  ```bash
  tccutil reset Accessibility dev.gimbap.mybar
  tccutil reset ScreenCapture dev.gimbap.mybar
  ```

  자기 사용자의 항목이라 관리자 권한 없이 된다.
- DMG 창에서 바로 실행하거나 격리 속성이 남은 채 Applications 밖에서 실행하면 macOS가 임시 위치
  (`…/AppTranslocation/…`)에서 돌린다(App Translocation). 이 사본에는 권한이 붙지 않는다.
- 권한 상태는 실행 중 프로세스에서 바로 갱신되지 않을 수 있어, 허용·초기화 후에는 MyBar를 다시 연다.

앱 안의 대응:

- Permissions 탭: DMG·임시 위치에서 실행 중이면 주황색 경고(`Permissions.locationProblem`).
- 권한이 하나라도 없으면 **Reset Permissions…** 버튼 → 위 두 초기화를 실행하고 MyBar를 다시 연다
  (`Permissions.resetAndRelaunch`).

## 번들 ID 변경 (1.4.0)

1.3.x까지는 `dev.mybar.MyBar`였다. macOS는 번들 ID별로 설정을 따로 두므로, 새 ID로 처음 실행할 때
예전 설정(숨김 배치·그룹·아이콘 등)을 그대로 가져온다(`PreviousIdentity.importSettings`, main.swift).
권한은 새 앱 기준이라 한 번 다시 허용해야 한다.

1.4.0 릴리스 노트에 넣을 것(1.3.x에서 올라오는 사람용):

- 권한을 한 번 다시 허용해야 한다(번들 ID·서명 변경). 예전 MyBar 권한 항목은 자동으로 지운다.
- 메뉴바의 MyBar 아이콘이 맨 왼쪽에 생길 수 있다 → ⌘-드래그로 원하는 곳에 한 번 옮기면 기억한다
  (macOS 27은 예전 위치 값을 새 ID에 적용하지 않음).
- 설정(숨김 배치·그룹·아이콘)은 자동으로 넘어온다.

## 1.4.1 릴리스 노트에 넣을 것

- macOS 27: 메뉴바 시계를 눌러도 알림 센터가 열리지 않던 문제 수정(1.3.0부터). MyBar가 숨기는 데 쓰는
  허용 목록이 켜져 있으면 macOS가 알림 센터를 막아서, 시계 클릭을 MyBar가 받아 잠깐 풀고 연다. 이때
  화면 기록 표시가 잠깐 생긴다. 트랙패드로 쓸어서 여는 것은 아직 안 된다.
- 다시 열 때 숨긴 아이템 그림이 옆 아이템과 섞여 찍히던 문제 수정.
