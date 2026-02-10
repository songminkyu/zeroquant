---
name: improve-test-coverage
description: Analyzes test coverage gaps for a specific crate and writes missing tests. Use WHEN a crate has insufficient test coverage or after major refactoring.
instructions: |
  ## 커버리지 개선 워크플로우

  ### Step 1: 현재 상태 분석
  대상 crate의 테스트 현황을 파악한다:
  ```powershell
  # 테스트 함수 목록
  $env:SQLX_OFFLINE="true"; cargo test -p <crate_name> -- --list 2>&1

  # cfg(test) 모듈 없는 파일 찾기
  Get-ChildItem crates/<crate>/src -Recurse -Filter *.rs | ForEach-Object {
      $content = Get-Content $_.FullName -Raw
      if ($content -notmatch '#\[cfg\(test\)\]' -and $_.Name -ne 'mod.rs' -and $_.Name -ne 'lib.rs') {
          Write-Host "NO TEST: $($_.FullName)"
      }
  }
  ```

  ### Step 2: 갭 분석 보고
  파일별로 테스트 유무를 정리하고 우선순위를 결정:
  - 🔴 Public 함수가 있는데 테스트 0개인 파일
  - 🟠 테스트가 있지만 에러 케이스/경계값 미커버
  - 🟡 테스트 충분하지만 리팩토링 후 갱신 필요

  ### Step 3: 테스트 작성
  파일별로 테스트 작성. 기존 패턴을 따른다:
  - 유닛: 소스 파일 하단 `#[cfg(test)] mod tests` 블록
  - 통합: `crates/<crate>/tests/기능명_test.rs`
  - 각 public 함수에 최소 happy path + 1 error case

  ### Step 4: 실행 및 검증
  ```powershell
  $env:SQLX_OFFLINE="true"; cargo test -p <crate_name> -- --nocapture
  ```
  전체 통과 확인 후 결과 보고.

  ### Step 5: 실패 보고
  테스트가 프로덕션 코드 버그를 발견하면:
  - 해당 테스트에 `#[ignore]` 태그 + 주석으로 버그 설명
  - lead에게 버그 보고 (파일, 라인, 증상, 재현 방법)
---
