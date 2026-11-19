# Aegis NPM 엔진 보안 후보

이 브랜치는 NGINX 보안 수정이 발표되면 NPM 공급자의 다음 이미지 배포를 기다리지 않고 후보를 만들기 위한 빌드 경로입니다. Dockerfile의 마지막 단계는 공급자의 NPM 2.12.6 이미지에서 시작합니다. 포크의 공개 기본 브랜치에 있는 백엔드는 2.12.3이며 운영 이미지에는 앱의 소스 커밋이 기록되어 있지 않습니다.

## 빌드와 검증

Linux amd64에서 Docker Engine과 Buildx, Bash, jq, Trivy를 준비하고 저장소 루트에서 실행합니다. CI에서 사용하는 Trivy 버전은 0.76.2입니다.

```sh
./security/check-candidate.sh
```

검증을 통과하면 로컬 태그 `aegis-npm:security-candidate`와 이미지 ID를 출력합니다. 같은 명령을 실행하는 GitHub Actions 구성 예제는 `security/github-actions.yml.example`에 있습니다. 운영 서버의 포트, 정책, 인증서, 데이터베이스 또는 Docker Compose 설정에 접근할 필요가 없습니다.

| 검증 | 통과 조건 |
| --- | --- |
| 엔진과 모듈 | 다시 빌드한 WAF와 HTTP·stream GeoIP2 모듈을 동시에 로드하고 Lua 및 WAF 설정이 `nginx -t`를 통과 |
| HTTPS | 임시 인증서로 TLS 1.3을 협상하고 HTTP/1.1과 HTTP/2에서 각각 Lua 응답과 HTTP 200을 확인 |
| NPM·MariaDB·WAF | NPM API로 임시 인증서와 프록시 호스트를 등록. 같은 DB·인증서·정책으로 기존 이미지 → 후보 → 기존 이미지 순서로 전환할 때마다 HTTP/2 프록시 응답과 새 에이전트의 WAF 등록을 확인 |
| 패키지 비교 | 동일한 Trivy 취약점 DB로 기존 이미지와 후보를 비교하고, 운영체제·언어 패키지에 새 HIGH·CRITICAL 항목이 생기면 중단 |

패키지 비교는 패키지 종류·이름·취약점 ID·심각도 조합의 차이를 계산합니다. 기존 이미지에서 이어받은 항목은 따로 조치해야 합니다. 소스로 빌드하는 NGINX의 수정 여부는 고정한 소스와 적용한 패치로 추적합니다.

## 2026-11-18 NGINX 보안 공지 대응

| 구성요소 | 후보의 기준 |
| --- | --- |
| NPM 앱 | 공급자 이미지 `ghcr.io/openappsec/nginx-proxy-manager-attachment@sha256:7a1f3e88d0e696234638eb15e85f0aa8707de5ab1b10fec0cd8e39282b13f486` |
| OpenResty | 공식 1.31.8.1 배포본과 SHA-256. 다운로드한 배포본의 서명 지문은 `25451EB088460026195BD62CB550E09EA0E98066` |
| NGINX 코어 | 1.31.8에서 1.31.9로 변경된 `src/` 파일 35개의 Git blob을 서명을 확인한 공식 배포본과 대조. 버전 식별용 헤더를 보존하고 나머지 34개 파일의 변경을 반영. `nginx -v`에 `aegis-nginx-core-1.31.9`를 표시 |
| GeoIP2 | `leev/ngx_http_geoip2_module` 커밋 `445df24ef3781e488cee3dfe8a1e111997fc1dfe` |
| open-appsec | `openappsec/attachment` 커밋 `1ed86d4cee4ae922a4b88d4d56656bcd10603600`. 후보와 같은 엔진 설정·헤더로 WAF와 보조 라이브러리 3개를 컴파일 |

Debian 런타임 라이브러리는 빌드 시점의 Bookworm 저장소에서 가져옵니다. 배포 대상을 지정할 때에는 시험을 마친 이미지의 다이제스트와 검사 결과를 함께 기록합니다. 새 공지가 나오면 Dockerfile과 빌드 스크립트에서 버전·커밋·해시를 갱신하고 같은 검증을 반복합니다.

운영 전환 시 실제 설정 및 인증서의 격리 복제본과 백업 복구를 검증하고, 이미지 다이제스트를 서명된 스택 릴리스에 기록합니다.

수정 대상은 NGINX 보안 공지와 공식 소스 변경 이력에서 확인할 수 있습니다. [NGINX 보안 공지](https://nginx.org/en/security_advisories.html) · [고정한 코어 변경 이력](https://github.com/nginx/nginx/compare/140aa942711868a8daeb95810bc9a81f272ada72...c2c44702c2fbc572e4cfb0a52331061d7fcaca16) · [OpenResty 배포본](https://openresty.org/en/download.html) · [open-appsec attachment](https://github.com/openappsec/attachment/tree/1ed86d4cee4ae922a4b88d4d56656bcd10603600)
