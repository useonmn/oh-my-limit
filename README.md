# Oh My Limit

Codex, Claude, Antigravity 구독 사용량을 메뉴바에서 보여주는 네이티브 macOS 앱입니다.
SwiftUI와 AppKit으로 만들었고 외부 패키지 의존성은 없습니다.

- 계정마다 5시간·주간·모델별 한도의 **사용한 비율**과 초기화 시각을 표시합니다.
- 같은 서비스의 여러 계정(예: ChatGPT 구독 두 개)을 따로 연결할 수 있습니다.
- 각 서비스에 브라우저로 직접 로그인합니다. Codex CLI, Claude Code, Antigravity 앱이 없어도 됩니다.
- 로그인 정보는 macOS 키체인에만 저장합니다.

## 설치

Apple Silicon Mac, macOS 14 이상이 필요합니다. 터미널에서 한 줄로 최신 릴리스를
`/Applications`에 설치합니다.

```sh
curl -fsSL https://raw.githubusercontent.com/useonmn/oh-my-limit/main/scripts/install.sh | bash
```

같은 명령을 다시 실행하면 최신 버전으로 업데이트됩니다. 실행 중인 앱은 자동으로
종료한 뒤 교체하고 다시 엽니다.

DMG로 설치하려면 [Releases](https://github.com/useonmn/oh-my-limit/releases)에서 받아
앱을 `Applications`로 드래그합니다. 이 앱은 Apple 공증을 받지 않았으므로 브라우저로
받은 DMG는 첫 실행이 차단될 수 있습니다. 그때는 **시스템 설정 → 개인정보 보호 및 보안 →
그래도 열기**로 허용합니다.

## 처음 실행

메뉴바의 계기판 아이콘을 클릭합니다. Dock에는 표시되지 않습니다.
처음 정상 실행할 때 macOS 로그인 항목으로 등록되어 다음 로그인부터 자동으로 실행됩니다.
앱 설정의 **로그인 시 실행** 또는 **시스템 설정 → 일반 → 로그인 항목 및 확장 프로그램**에서
끌 수 있습니다.

로그인 정보를 처음 읽거나 저장할 때 macOS가 키체인 접근을 물으면 **항상 허용**을 누릅니다.

## 계정 연결

**설정 → 계정 추가**에서 서비스를 고르고 연결 버튼을 누르면 브라우저 로그인이 열립니다.
메뉴바 패널의 **계정 연결…**로도 설정을 열 수 있습니다. 같은 버튼으로 계정을 더 추가할 수 있고,
계정마다 사용량을 따로 표시합니다. 브라우저가 다른 계정으로 자동 로그인되어 있다면
원하는 계정을 직접 선택하세요.

**연결 해제**는 그 계정의 앱 내 로그인 정보와 캐시만 지웁니다. 각 서비스의 CLI나
다른 앱의 로그인은 바꾸지 않습니다.

### Codex

- **ChatGPT 계정 연결**로 로그인합니다. 사용량 조회에 필요한
  `openid profile email offline_access` 권한만 요청합니다.
- Codex CLI나 `~/.codex` 폴더는 사용하지 않습니다.
- 크레딧으로 과금되는 좌석은 **크레딧 한도**를 표시하고, 크레딧 잔액이 있으면 함께 보여줍니다.

### Claude

- **Claude 계정 연결**로 로그인하고 사용량 읽기 권한(`user:profile`)을 허용합니다.
- 5시간·주간·모델별 주간 한도를 표시하고, 추가 사용량(overage)이 켜져 있으면
  **추가 사용량**으로 금액을 보여줍니다.
- Claude Code의 키체인 항목이나 `~/.claude` 파일은 읽지 않으며, 앱이 자체 갱신 토큰으로
  로그인을 유지합니다.
- Claude API 키, Bedrock, Vertex 연결은 이 구독 사용량 조회에 포함되지 않습니다.

### Antigravity

- **Google 계정 연결**로 로그인합니다. Antigravity 앱이나 CLI는 필요하지 않습니다.
- 로그인 성공과 한도 조회 권한은 별개입니다. 한도가 제공되지 않으면 계정 이메일과
  **로그인됨 · 사용량 미확인**을 표시합니다.
- 이미 Antigravity 앱·IDE나 공식 `agy` CLI(1.1.11 이상)에 로그인했다면
  **로컬 앱·CLI로 연결 → 현재 로컬 계정 연결**도 쓸 수 있습니다. 이 연결은 로컬 로그인
  하나를 따라가므로, Antigravity에서 계정을 바꾸면 다음 조회부터 표시 계정도 바뀝니다.
  로컬 응답에 이메일이 없으면 **이메일 미제공**으로 표시합니다.
- 로컬 연결은 실행 중인 Antigravity 앱, `agy`, IDE의 로컬 서버를 먼저 확인하고,
  안 되면 같은 `agy`의 버전을 확인한 뒤 다음 명령의 JSON 출력을 읽습니다.

  ```sh
  agy -p "/usage" --output-format json --print-timeout 90s
  ```

  모델 요청이나 터미널 화면 파싱은 하지 않습니다. 빈 작업 폴더, 비대화형 입력,
  출력 크기와 시간 제한을 적용하고 취소하면 프로세스를 종료합니다.

## 화면 보기

- 패널 위쪽의 링은 계정별 **사용한 비율**이고, 링 아래에 계정 이름과 기준 시간창이 표시됩니다.
  링을 누르면 그 계정의 시간창별 사용량과 초기화 시각이 아래에 나옵니다.
- 메뉴바에는 연결 순서대로 최대 3개 계정의 **서비스 로고와 사용률**이 표시됩니다.
  나머지나 폭(240 pt)에 들어가지 않는 계정은 `+N`으로 묶이고, 계정이 없으면 게이지 아이콘만 보입니다.
  계정 이름은 메뉴바에 마우스를 올리거나 패널을 열면 보입니다.
- 민트색은 정상, 주황색은 80% 이상, 빨간색은 95% 이상입니다.
- `—`는 미확인·미제공이거나 초기화 시각이 지난 값, `~`는 오래됐거나 조회에 실패한 마지막 값입니다.
- 새로고침은 패널 위쪽, 다시 로그인·연결 해제는 선택한 계정의 **…** 메뉴에 있습니다.
- 패널은 시스템의 밝게/어둡게 모드를 따르며, macOS 26 이상에서는 Liquid Glass로 표시됩니다.

## 표시와 갱신

- 메뉴바와 링은 주간 한도를 우선 표시합니다.
  - Codex는 본 모델 한도만 사용하며, reserve·추가 모델 수치로 대체하지 않습니다.
  - Claude는 전체 주간 한도를, 없으면 5시간 한도를 표시합니다. 모델별 한도로 대체하지 않습니다.
  - Antigravity는 알려진 주간 한도 중 가장 많이 사용한 값을, 없으면 다른 알려진 한도를 표시합니다.
- 서버가 준 시간창만 표시하고, 시간창 길이를 추측해서 만들지 않습니다. 모델별·추가 한도도
  별도 행으로 보여줍니다. Antigravity가 새로운 종류의 한도를 보내도 버리지 않고 표시합니다.
- 서버가 사용량 값을 주지 않은 한도는 0%가 아니라 **알 수 없음**으로 표시합니다. 다만 Antigravity가
  남은 비율 없이 초기화 시각만 보내거나 남은 양을 0으로 보내면 소진(100%)으로 표시합니다.
- 초기화 시각이 지나도 잔여량이 복원됐다고 가정하지 않습니다.
- 정상일 때 Codex는 약 1분, Claude와 Antigravity는 5분마다 확인합니다. 메뉴를 열거나
  잠자기에서 돌아오면 이 주기에 따라 오래된 값을 갱신합니다.
- 실패하면 마지막 성공값을 유지하고 자동 재시도 간격을 1분부터 최대 15분까지 늘립니다.
  Claude가 요청 제한(429)을 알리면 서버가 정한 시간(최대 1시간)과 평소 주기 중 긴 쪽만큼 기다립니다.
- 같은 계정의 중복 조회를 합치고, 한 계정의 로그인이나 오류가 다른 계정의 데이터를 덮어쓰지 않습니다.

## 인증과 데이터

- 세 서비스 모두 각 서비스의 공식 CLI·앱과 같은 **공개 OAuth 클라이언트**로 브라우저 로그인합니다.
  그래서 서비스 쪽에서 언제든 이 접근 방식을 바꾸거나 막을 수 있습니다. OAuth 클라이언트
  설정과 출처는 `CodexOAuthTypes.swift`, `ClaudeOAuth.swift`, `AntigravityOAuthTypes.swift`에 있습니다.
- 사용량 조회만 합니다. 추론 요청, 에이전트 작업, 프로젝트 생성은 하지 않고 웹 쿠키도 수집하지 않습니다.
- 접속하는 곳:
  - Codex: `auth.openai.com`(로그인), `chatgpt.com`(사용량)
  - Claude: `claude.com`·`platform.claude.com`(로그인), `api.anthropic.com`(사용량)
  - Antigravity: Google 로그인, `cloudcode-pa.googleapis.com`(계정 정보),
    `daily-cloudcode-pa.googleapis.com`(한도, 일시 장애 시 `daily-cloudcode-pa.sandbox.googleapis.com`).
    서버가 클라이언트 버전을 확인하므로, 실행 중 한 번 Antigravity 공식 업데이트 서버
    (`antigravity-hub-auto-updater-…run.app`)에서 최신 버전 번호만 확인해 요청에 씁니다.
    로그인 정보는 이 서버로 보내지 않습니다.
  - Antigravity 로컬 연결: `127.0.0.1`의 로컬 서버. 로컬 서버의 자체 서명 인증서는 루프백 주소에서만 허용합니다.
- 리다이렉트를 따라가지 않고 공유 쿠키를 쓰지 않습니다. 브라우저 로그인 콜백은 무작위 state와
  PKCE를 검증하는 루프백 서버로 받습니다.
- 로그인 토큰은 계정별로 앱 전용 키체인 서비스(`local.ohmylimit.codex.oauth`,
  `local.ohmylimit.claude.oauth`, `local.ohmylimit.antigravity.oauth`)에만 저장하고,
  설정·캐시 파일이나 로그에는 기록하지 않습니다.
- 계정 목록과 마지막 사용량은 사용자 전용 권한으로 다음 위치에 저장합니다. 캐시에는 계정
  이메일이 포함될 수 있습니다.

  ```text
  ~/Library/Application Support/OhMyLimit/
    accounts.json                  # 계정 목록 (버전 3)
    snapshots/<account UUID>.json  # 계정별 마지막 사용량
  ```

  캐시는 계정 UUID·경로·서비스·인증 방식, 직접 연결은 로그인한 계정 ID까지 일치할 때만 복원합니다.
- 예전 버전에서 Codex CLI 또는 Claude Code 로그인을 빌려 쓰던 계정은 앱을 열 때 목록에서
  빠지고 안내가 표시됩니다. CLI의 로그인 파일은 건드리지 않으니 브라우저 로그인으로 다시 연결하면 됩니다.

## 제거하기

1. 앱 설정에서 **로그인 시 실행**을 끄거나 **시스템 설정 → 일반 → 로그인 항목 및 확장 프로그램**에서 Oh My Limit을 제거합니다.
2. 메뉴바의 Oh My Limit을 종료하고 `/Applications/OhMyLimit.app`을 삭제합니다.
3. (선택) 계정 목록과 마지막 사용량: `~/Library/Application Support/OhMyLimit/` 폴더를 삭제합니다.
4. (선택) 로그인 토큰: 키체인 접근 앱에서 서비스 이름이 `local.ohmylimit.codex.oauth`,
   `local.ohmylimit.claude.oauth`, `local.ohmylimit.antigravity.oauth`인 항목을 삭제합니다.
5. (선택) 앱 환경설정: `defaults delete local.ohmylimit.app`을 실행합니다.

## 개발

Swift 6 이상이 포함된 Xcode 또는 Command Line Tools가 필요합니다.

```sh
xcode-select --install          # Command Line Tools가 없을 때만
git clone https://github.com/useonmn/oh-my-limit.git
cd oh-my-limit
./scripts/test.sh               # 테스트
./scripts/build-app.sh          # dist/OhMyLimit.app
open dist/OhMyLimit.app
```

저장소에는 계정 정보나 인증 토큰이 없고, 테스트도 실제 계정이나 네트워크를 쓰지 않습니다.
Antigravity 테스트는 루프백 HTTP 서버와 가짜 CLI로 파싱, 계정 식별, 로컬 우선순위,
CLI 버전 검사, 출력 제한, 취소와 정리를 검증합니다. OAuth 테스트는 콜백, 토큰 교환·갱신,
계정별 저장·해제, 한도 거절, 리다이렉트 차단, 취소 중 늦은 응답을 검증합니다.
테스트 통과가 실제 계정의 권한이나 한도 제공을 보장하지는 않으니 실제 조회는 각자 계정으로 확인하세요.

### 서명 인증서 (소스에서 빌드할 때만)

`build-app.sh`는 `Oh My Limit Dev` 인증서가 있으면 그것으로, 없으면 임시(ad-hoc)로 서명합니다.
임시 서명은 빌드할 때마다 다른 앱으로 인식되어 키체인 접근을 다시 묻습니다. 자체 서명 인증서를
한 번 만들어 두면 다시 빌드해도 키체인 허용이 유지됩니다.

```sh
T="$(mktemp -d)"; P="$(uuidgen)"
cat > "$T/c.cnf" <<'EOF'
[req]
distinguished_name=dn
prompt=no
x509_extensions=ext
[dn]
CN=Oh My Limit Dev
[ext]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
EOF
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 7300 -config "$T/c.cnf" \
  -keyout "$T/k.pem" -out "$T/c.pem"
/usr/bin/openssl pkcs12 -export -inkey "$T/k.pem" -in "$T/c.pem" -name "Oh My Limit Dev" \
  -out "$T/i.p12" -passout "pass:$P"
security import "$T/i.p12" -k ~/Library/Keychains/login.keychain-db -P "$P" -T /usr/bin/codesign
rm -rf "$T"
```

- 개인 키는 로그인 키체인에만 남고 임시 파일은 지워집니다. 저장소에 넣지 마세요.
- Homebrew 등의 OpenSSL 3가 만드는 PKCS#12는 `security import`가 거부하므로 `/usr/bin/openssl`을 씁니다.
- 처음 서명할 때 `codesign`의 키 사용 허용 창이 뜨면 Mac 암호를 입력하고 **항상 허용**을 누릅니다.
- `security find-identity -p codesigning`의 `CSSMERR_TP_NOT_TRUSTED`는 자체 서명 인증서에서 정상입니다.
- 임시 서명 앱이 만든 키체인 항목은 새 서명으로 처음 실행할 때 항목마다 한 번 **항상 허용**을 눌러야 합니다.

### DMG와 릴리스

```sh
./scripts/build-dmg.sh   # dist/OhMyLimit-<버전>-macOS-arm64.dmg
./scripts/release.sh     # GitHub 릴리스 v<버전> 생성 또는 갱신
```

`release.sh`는 `gh` 로그인 상태에서 `Resources/Info.plist`의 버전으로 릴리스를 만들고, 설치
스크립트가 받는 `OhMyLimit-macOS-arm64.zip`과 DMG를 올립니다. 사용자의 키체인 허용이 업데이트
후에도 유지되도록 릴리스는 항상 같은 인증서로 서명하세요.

### 확인용 도구

로컬 Antigravity 계정의 실제 조회 결과를 출력합니다. 이메일이나 토큰은 출력하지 않습니다.

```sh
BIN="$(xcrun swift build --show-bin-path)"
"$BIN/OhMyLimit" --probe-antigravity
"$BIN/OhMyLimit" --probe-antigravity --antigravity-cli "/path/to/agy"
```

사용량·오류·로그인 상태와 설정 화면을 밝게/어둡게 모드로 렌더링해 `dist/previews/`에 저장합니다.
미리보기 계정은 임시 폴더에만 만들고 실제 계정 목록에는 저장하지 않습니다.

```sh
bash scripts/capture-previews.sh
```

### 개발 참고

- Swift 6.4 Command Line Tools에는 SwiftUI의 새 `@State` 매크로 플러그인이 없어서,
  설정 입력은 `ObservableObject`/`StateObject`로 관리합니다.
- 기본 빌더는 증분 빌드 상태에 따라 `TestingMacros` 플러그인을 빠뜨릴 수 있습니다.
  `scripts/test.sh`는 도구 체인에 플러그인이 있으면 그 경로를 명시해 테스트를 실행합니다.

### 구성

- `Sources/OhMyLimitCore`: OAuth 로그인, 사용량 조회, 계정 저장, 조회 상태와 캐시
- `Sources/OhMyLimit`: 메뉴바, 팝오버, 설정, 화면 미리보기
- `Tests/OhMyLimitCoreTests`: 프로토콜과 계정·상태 회귀 테스트
- `scripts/`: 테스트, 빌드, DMG, 릴리스, 설치 스크립트
- `DESIGN.md`: 화면과 접근성 기준

## 라이선스

[MIT](LICENSE). 서비스 로고(LobeHub Icons)와 사용량 조회 로직 일부(oh-my-pi)의 출처와 라이선스는
`Resources/ThirdPartyNotices.md`에 있습니다.

OpenAI·ChatGPT·Codex, Anthropic·Claude, Google·Antigravity의 이름과 로고는 각 소유자의
상표입니다. 이 프로젝트는 비공식 프로젝트이며 이들 회사와 제휴하거나 보증을 받지 않았습니다.
로고는 연결된 서비스를 식별하는 용도로만 사용합니다.
