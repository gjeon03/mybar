# 서명·공증·릴리스

## 처음 한 번 (릴리스하는 Mac)

1. Apple Developer Program 계정으로 **Developer ID Application** 인증서를 만든다.
   Xcode → Settings → Accounts → (팀) → Manage Certificates → + → Developer ID Application.
   `security find-identity -v -p codesigning`에 `Developer ID Application: …`이 보이면 된다.
2. 공증용 자격 증명을 키체인에 저장한다(앱 암호는 appleid.apple.com에서 만든다).

   ```bash
   xcrun notarytool store-credentials mybar --apple-id <Apple ID> --team-id <팀 ID> --password <앱 암호>
   ```

## 릴리스

```bash
# 1. Resources/Info.plist의 CFBundleShortVersionString, CFBundleVersion 올리기
swift format lint -r Sources Tests && swift test
MYBAR_NOTARY_PROFILE=mybar scripts/package.sh build   # 유니버설 앱 → 서명 → DMG → 공증 → 스테이플
gh release create v<버전> build/MyBar-<버전>.dmg --title "MyBar <버전>" --notes "…"
```

- `scripts/signing.sh`가 서명 인증서를 고른다: `MYBAR_SIGN_IDENTITY` → 키체인의 Developer ID
  Application → 애드혹(`-`). 무엇으로 서명됐는지는 스크립트 마지막 줄과 `codesign -dr - <앱>`으로 확인.
- 공증은 `MYBAR_NOTARY_PROFILE`이 있을 때만 하고, 끝나면 `spctl --assess`로 확인한다.
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
