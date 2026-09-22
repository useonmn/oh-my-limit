# Oh My Limit

Codex와 Antigravity 구독 사용량을 보여주는 네이티브 macOS 메뉴바 앱입니다.
SwiftUI와 AppKit을 사용하며 외부 패키지 의존성은 없습니다.

## 새 Mac에서 복원

이 저장소에는 앱을 다시 빌드하는 데 필요한 소스, 리소스, 테스트와 스크립트가
포함됩니다. 새 Mac에서는 다음 순서로 복원합니다.

```sh
xcode-select --install
git clone https://github.com/useonmn/oh-my-limit.git
cd oh-my-limit
./scripts/test.sh
./scripts/build-app.sh
cp -R dist/OhMyLimit.app /Applications/
open /Applications/OhMyLimit.app
```

`xcode-select --install`은 이미 Command Line Tools가 설치되어 있으면 생략합니다.
Git에는 개인 계정 정보나 인증 토큰을 저장하지 않습니다. 따라서 새 Mac에서는
앱을 처음 열고 Codex와 Antigravity 계정을 다시 연결해야 합니다. 기존 Mac의
키체인, `~/Library/Application Support/OhMyLimit/`, Codex 홈 폴더도 저장소에
포함되지 않습니다.

## 실행

필요한 환경:

- macOS 14 이상
- Swift 6 이상이 포함된 Xcode 또는 Command Line Tools
- Codex 직접 연결: ChatGPT 계정과 브라우저 (CLI 설치 불필요)
- Codex 로컬 연결: 로그인된 공식 Codex CLI
- Antigravity 직접 연결: Google 계정과 브라우저 (앱·CLI 설치 불필요)
- Antigravity 로컬 연결: 로그인된 Antigravity 앱/IDE 또는 공식 `agy` CLI 1.1.11 이상

```sh
./scripts/build-app.sh
open dist/OhMyLimit.app
```

메뉴바의 계기판 아이콘을 클릭합니다. Dock에는 표시되지 않습니다.
`dist/OhMyLimit.app`을 Applications 폴더로 복사해 사용할 수도 있습니다.
현재 빌드는 로컬 ad-hoc 서명이며 Developer ID 공증 배포본은 아닙니다.
첫 정상 실행 때 사용자 LaunchAgent로 등록되며, 다음 macOS 로그인부터 자동 실행됩니다.
자동 실행은 **시스템 설정 → 일반 → 로그인 항목 및 확장 프로그램**에서 끌 수 있습니다.

## 원형 사용률 패널

상단의 서비스 아이콘을 감싼 링은 계정별 **사용한 비율**입니다.
링 아래 계정 이름으로 Codex 구독 두 개를 구분할 수 있습니다.
원하는 링을 누르면 아래에 그 계정의 시간창별 사용량과 초기화 시각이 표시됩니다.
메뉴바에는 계정 번호 대신 **서비스 로고와 사용률**이 연결 순서대로 표시됩니다.
같은 서비스의 계정 이름은 메뉴바에 마우스를 올리거나 패널을 열어 확인할 수 있습니다.

- 주간 한도를 우선 표시하며, 링 아래에 사용한 시간창을 적습니다.
- 민트색은 정상 범위, 주황색은 80% 이상, 빨간색은 95% 이상입니다.
- `—`는 미확인·미제공·초기화 시각이 지난 값, `~`는 마지막 확인값입니다.
- 계정이 많으면 링 영역을 좌우로 스크롤합니다. 긴 상세 정보는 고정된 카드 안에서만
  스크롤되며, 스크롤바 유무와 관계없이 카드 폭·여백·둥근 모서리가 유지됩니다.
- 새로고침은 상단, 다시 로그인·연결 해제는 선택한 계정의 **…** 메뉴에 있습니다.
- 패널은 참고 이미지에 맞춰 항상 어둡게 표시하며 설정 창은 시스템 테마를 따릅니다.

## Codex 계정 두 개 연결하기

1. **현재 Codex 계정 연결**을 누르면 현재 `CODEX_HOME` 또는 `~/.codex`를
   연결합니다. 로그인 파일을 복사하지 않습니다.
2. 우측 상단 **+** 또는 설정에서 계정 이름을 입력하고 **새 계정으로 로그인**을
   누릅니다.
3. 공식 로그인 페이지에서 두 번째 계정으로 로그인합니다. 브라우저가 첫 번째
   계정으로 자동 로그인되어 있다면 원하는 계정을 직접 선택해 주세요.
4. 각 계정의 사용률과 초기화 시각을 별도로 확인합니다.

기존에 계정마다 Codex 홈 폴더를 나눠 사용하고 있다면 설정의
**기존 Codex 폴더 선택**으로 각각 연결할 수 있습니다.

**연결 해제**는 앱의 계정 목록만 변경합니다. Codex 인증 파일을 삭제하거나
기존 터미널을 로그아웃시키지 않습니다. 기존 폴더의 **다시 로그인**은 그 폴더의
Codex 인증을 갱신하므로, 기존 터미널 계정과 분리하려면 새 계정을 추가하세요.

## Antigravity 연결하기

1. **설정 → Antigravity → Google 계정으로 로그인**을 누릅니다.
2. 브라우저에서 연결할 계정을 선택하고 인증을 완료합니다.
3. 계정별 사용량을 확인합니다. 다른 계정도 같은 버튼으로 추가할 수 있습니다.
   Antigravity 앱·CLI와 Codex CLI는 필요하지 않습니다.

직접 연결은 계정별로 인증정보를 macOS 로그인 키체인에 보관하고 만료 시 갱신합니다.
로그인 성공과 한도 조회 권한은 별개입니다. 인증 후 한도가 제공되지 않으면
계정 이메일과 **로그인됨 · 사용량 미확인**을 표시합니다.
**연결 해제**는 해당 계정의 앱 내 인증정보와 캐시도 삭제하며 Google 전체를
로그아웃하거나 다른 앱의 인증을 변경하지 않습니다.

이미 앱·CLI에서 로그인했다면 **현재 로컬 계정 연결**도 사용할 수 있습니다.
이 연결만 로컬 로그인 하나를 따라갑니다. Antigravity에서 계정을 바꾸면
다음 조회부터 표시 계정도 바뀝니다. CLI JSON에 이메일이 없으면 이전 이메일을
이어 붙이지 않고 **이메일 미제공**으로 표시합니다.

직접 연결은 인증한 계정의 Google 원격 한도 API만 조회하며 로컬 계정으로
대체하지 않습니다. 로컬 연결은 실행 중인 Antigravity 앱, `agy`, IDE를 우선 확인합니다.
로컬 조회가 불가능하면 같은 실행 파일의 버전을 확인한 뒤 다음 명령을 실행합니다.

```sh
agy -p "/usage" --output-format json --print-timeout 90s
```

모델 요청이나 터미널 화면 파싱은 하지 않습니다. CLI 조회에는 빈 작업 폴더,
비대화형 표준 입력, 출력 크기 제한과 시간 제한을 적용하며 취소 시 프로세스를
종료하고 회수합니다.

## 표시와 갱신

- 숫자는 **사용한 비율**입니다.
- 메뉴바와 원형 요약은 주간 한도를 우선 표시합니다. Codex는 본 모델의
  `codex` 한도만 사용하며 reserve·추가 모델의 수치로 대체하지 않습니다.
  본 모델 주간 한도가 100%면 reserve 잔여량과 관계없이 100%입니다.
  Antigravity는 알려진 주간 창 중 가장 많이 사용한 값을 선택합니다. 해당
  주간 값이 없으면 같은 대상의 알려진 다른 창을 사용합니다.
  `~`는 오래됐거나 조회가 실패한 마지막 값입니다.
- 서버가 제공한 시간창만 표시합니다. Antigravity의 그룹형 응답은 네 가지
  표준 창으로 표시하며, 미제공 값은 **알 수 없음**입니다. 모델별 응답의
  시간창 길이가 없으면 5시간·주간으로 추정하지 않습니다.
- 모델별 추가 한도도 별도 행으로 표시합니다.
- 초기화 시각이 지나도 잔여량이 복원됐다고 가정하지 않습니다.
- 정상 상태에서는 Codex는 60초, Antigravity는 5분마다 확인합니다.
  메뉴를 열거나 잠자기에서 돌아오면 해당 주기에 따라 오래된 값을 갱신합니다.
- 실패 시 마지막 성공값을 유지하고, 자동 재시도 간격을 최대 15분까지 늘립니다.
- 같은 계정의 중복 조회를 합칩니다. 다른 계정의 로그인/오류가 그 계정의
  데이터를 덮어쓰지 않습니다.

## 인증과 데이터

Codex는 `codex app-server`의 `account/read`, `account/rateLimits/read`와
공식 로그인 RPC를 사용합니다. 추론 요청이나 에이전트 작업을 실행하지 않습니다.
Antigravity 직접 연결은 PKCE와 무작위 state를 검증하는 루프백 OAuth 콜백을
사용합니다. 계정 정보는 `cloudcode-pa.googleapis.com`, 한도는
`daily-cloudcode-pa.googleapis.com`에서 조회합니다. OpenCodex 2.55.0과 같은
Antigravity IDE 클라이언트 계약을 사용하며 리다이렉트와 공유 쿠키는 쓰지 않습니다.
공개 네이티브 OAuth 클라이언트
설정의 출처는 `AntigravityOAuthTypes.swift`에 기록되어 있습니다.
로컬 연결은 Connect-RPC 또는 공식 CLI JSON 출력을 사용합니다.
로컬 통신의 자체 서명 인증서는 루프백 주소에서만 허용하고 리다이렉트는 거부합니다.
웹 쿠키를 수집하거나 추론·프로젝트 생성 요청을 보내지 않습니다.

앱 설정과 마지막 사용량은 다음 위치에 저장됩니다.

```text
~/Library/Application Support/OhMyLimit/
  accounts.json
  profiles/<account UUID>/       # 앱에서 새로 로그인한 계정의 CODEX_HOME
  snapshots/<account UUID>.json  # 계정별 마지막 사용량
```

직접 연결의 OAuth 액세스/갱신 토큰은 키체인의
`local.ohmylimit.antigravity.oauth` 서비스 아래 계정 UUID별로 저장합니다.
토큰은 설정·캐시 파일이나 로그에 기록하지 않으며 다른 앱의 키체인을 읽지 않습니다.
Antigravity 로컬 통신에 필요한 프로세스 CSRF 값만 메모리에서 사용합니다.
**Codex CLI가** 각 홈의 로그인과 인증 갱신을 담당하며 새 로그인에는 별도 홈을 사용합니다.
설정과 캐시는 사용자 전용 권한으로 저장하며 캐시에 계정 이메일이 포함될 수 있습니다.
기존 버전 1·2 설정은 기존 로컬 연결로 복원합니다. 저장할 때는 인증 방식이
포함된 버전 3을 사용합니다. 캐시는 계정 UUID·경로·제공자·인증 방식이 일치할 때만
복원하며, 직접 연결은 인증한 Google 계정 ID도 대조합니다.

## 개발과 검증

```sh
./scripts/test.sh
xcrun swift build
```

설치된 Codex의 현재 계정으로 실제 RPC 조회를 확인할 수 있습니다. 출력에는
이메일이나 토큰이 포함되지 않습니다.

```sh
BIN="$(xcrun swift build --show-bin-path)"
"$BIN/OhMyLimit" --probe
"$BIN/OhMyLimit" --probe --codex-home "/path/to/codex-home"
"$BIN/OhMyLimit" --probe-antigravity
"$BIN/OhMyLimit" --probe-antigravity --antigravity-cli "/path/to/agy"
```

테스트는 실제 파이프를 쓰는 가짜 Codex 프로세스로 프로토콜, 타임아웃,
취소, 프로세스 종료, 로그인 완료 이벤트를 검증합니다. 추가 테스트는 계정
분리, 저장/복원, 중복 요청, 오래된 응답 폐기, 실패 시 마지막 값 유지를 확인합니다.
테스트는 실제 계정이나 인증 토큰을 사용하지 않습니다.
Antigravity 테스트는 실제 루프백 HTTP 서버와 가짜 CLI 실행 파일로 파싱,
계정 식별, 로컬 우선순위, CLI 버전 검사, 출력 제한, 취소와 정리를 검증합니다.
직접 OAuth 테스트는 콜백, 토큰 교환·갱신, 계정별 저장·해제, 원격 한도 거절,
리다이렉트 차단과 취소 중 늦은 응답을 검증합니다.

화면을 재현하려면:

```sh
bash scripts/capture-previews.sh
```

22개 시나리오의 각 계정 선택 상태와 긴 상세·설정의 스크롤 끝을
라이트/다크 시스템 환경에서 렌더링해 `.omo/evidence/`에 저장합니다.
미리보기 데이터는 명시적으로 표시되며 실제 계정 목록에 저장되지 않습니다.
기본 실행은 항상 실제 계정 데이터를 사용합니다.

### 환경에서 확인한 제한

- Swift 6.4 Command Line Tools에서는 SwiftUI의 새 `@State` 매크로 플러그인이
  빠져 있어, 설정 입력은 호환되는 `ObservableObject`/`StateObject`로 관리합니다.
- 이 환경의 기본 Swift 빌더가 존재하지 않는 Command Line Tools 링크 검색 경로
  경고를 출력합니다. 빌드와 테스트는 통과하며 경고를 숨기지 않습니다.
- `--build-system native`는 이 환경에서 `Testing` 모듈을 찾지 못하므로 기본
  빌더를 사용합니다.
- 기본 빌더도 증분 빌드 상태에 따라 `TestingMacros` 플러그인을 누락할 수
  있습니다. `scripts/test.sh`는 선택된 Swift 도구 체인의 플러그인이 있으면
  그 경로를 명시해 테스트를 실행합니다.
- 브라우저에서 실제 두 번째 계정의 인증을 완료하는 단계는 사용자가 수행해야
  합니다. 로컬 테스트는 그 인증 정보를 요구하지 않습니다.
- Google 직접 로그인과 실제 구독 한도 제공 여부도 사용자가 선택한 계정으로
  확인해야 합니다. 테스트 통과만으로 실계정 권한을 보장하지 않습니다.
- SourceKit의 단일 파일 진단은 이 환경에서 로컬 Swift 모듈/Testing을 찾지
  못하는 경우가 있습니다. 실제 컴파일과 테스트 결과로 별도 확인합니다.

## 구성

- `Sources/OhMyLimitCore`: RPC, 계정 저장, 조회 상태와 캐시
- `Sources/OhMyLimit`: 메뉴바, 팝오버, 설정, 화면 미리보기
- `Tests/OhMyLimitCoreTests`: 프로토콜과 계정/상태 회귀 테스트
- `DESIGN.md`: 화면과 접근성 기준
