# 선택적 Third-Party 연동

PhotoArchiveKit의 required core는 아래 도구를 포함, link, vendor, download, redistribute하지 않는다. CLI는 사용자가 설치한 executable을 감지할 수 있고, future adapter는 명시적 user command 이후 별도 process로 호출할 수 있다.

연동 가능한 project를 이름으로 언급하는 것은 일반적인 open-source practice다. external dependency를 숨기는 것보다 명확하다. 문서와 UI는 sponsorship, endorsement, affiliation을 암시해서는 안 된다.

## rclone

- 목적: optional off-site archive copy 및 verification
- integration model: user-installed `rclone` executable 호출
- Upstream: <https://rclone.org/>
- Upstream license: MIT
- PhotoArchiveKit에 bundle: 아니오

초기 adapter는 보수적인 `copy`와 `check` operation을 생성하거나 실행해야 한다. destructive `sync`를 default로 선택하지 않는다.

## Czkawka CLI

- 목적: optional additional exact-duplicate 및 perceptual-similarity candidate 생성
- integration model: user-installed `czkawka_cli` executable 호출 후 sanitized result import
- Upstream: <https://github.com/qarmin/czkawka>
- `czkawka_core`, `czkawka_cli`에 해당하는 upstream license: MIT
- PhotoArchiveKit에 bundle: 아니오

similarity output은 review signal이다. PhotoArchiveKit이 이를 직접 deletion으로 바꾸어서는 안 된다.

## Krokiet

- 목적: 사용자가 GUI를 독립적으로 사용해 duplicate/similarity candidate를 검토할 수 있음
- integration model: required integration 계획 없음. file 또는 user decision을 통해 간접 interoperability 가능
- Upstream: <https://github.com/qarmin/czkawka>
- finished application license: upstream 설명에 따르면 GUI framework licensing 때문에 GPL-3.0-only
- PhotoArchiveKit에 bundle: 아니오

자동 optional subprocess adapter에는 별도 license의 Czkawka CLI를 우선한다. 새로운 packaging/license review 없이 MIT release 안에 Krokiet을 redistribute하지 않는다.

## ExifTool

- 목적: optional broad metadata diagnostic, migration investigation, PhotoArchiveKit native probe와 비교
- integration model: user-installed `exiftool` process 호출
- Upstream: <https://exiftool.org/>
- Upstream license: upstream 설명에 따르면 Perl과 동일한 조건
- PhotoArchiveKit에 bundle: 아니오

초기 설계에서는 ExifTool을 read-only로 취급한다. Live Photo identifier 또는 source metadata rewrite는 초기 release 범위 밖이다.

## osxphotos

- 목적: optional Apple Photos library query/export, album interoperability, original/edited representation 조사, future import bridge 검증
- integration model: user-installed `osxphotos` executable 호출 또는 사용자가 독립적으로 실행한 결과 import
- Upstream: <https://github.com/RhetTbull/osxphotos>
- Upstream license: MIT
- PhotoArchiveKit에 bundle: 아니오

osxphotos는 현재 required scanner dependency가 아니다. 초기 adapter가 생기더라도 read/query/export를 우선하고 Photos를 변경하는 operation은 별도 test library에서 검증한다. 장기적인 공식 Apple Photos projection은 PhotoKit을 우선한다.

## FFmpeg / ffprobe

- 목적: optional video stream/container diagnostic
- integration model: user-installed `ffprobe` process 호출
- Upstream: <https://ffmpeg.org/>
- Upstream license: 일반적으로 LGPL 2.1 이상이지만 enabled component에 따라 build가 GPL이 될 수 있음
- PhotoArchiveKit에 bundle: 아니오

license가 binary build 방식에 따라 달라질 수 있으므로 초기 project에서는 generic ffprobe binary를 redistribute하지 않는다.

## Apple system framework

Swift package는 macOS에서 제공하는 다음 system framework/library를 link한다.

- Foundation
- ImageIO
- AVFoundation
- CryptoKit
- SQLite3

이들은 vendored project dependency가 아니라 platform requirement다.

## 미래에 bundling을 고려한다면

third-party binary 또는 source distribution을 추가하기 전에:

1. 정확한 component와 version을 식별한다.
2. license와 실제 build configuration의 license를 확인한다.
3. 필요한 copyright/notice file을 추가한다.
4. 필요한 경우 source availability와 modification status를 문서화한다.
5. trademark 사용과 naming을 검토한다.
6. 가능하면 optional integration을 MIT core와 분리한다.
7. binary를 조용히 download하거나 실행하지 않는다.

이 파일은 project policy summary이며 legal advice가 아니다.
