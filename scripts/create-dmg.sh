#!/bin/bash
#
# HanFix DMG 생성 스크립트
# 빌드 → 코드 서명 → DMG 생성 → 공증 → 스테이플
#
# 사용법:
#   ./scripts/create-dmg.sh
#
# 필수 환경 변수 (export 또는 .env 파일):
#   DEVELOPER_ID        - Developer ID Application 인증서 이름
#   TEAM_ID             - Apple Developer Team ID (10자리)
#   APPLE_ID            - Apple ID 이메일
#   APP_PASSWORD        - App-Specific Password (앱 암호)
#
# 선택 환경 변수:
#   SKIP_NOTARIZE       - "true" 설정 시 공증 건너뛰기 (로컬 테스트용)
#   BUILD_CONFIG        - Debug 또는 Release (기본: Release)
#

set -euo pipefail

# ============================================================
# 설정
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
PROJECT_NAME="HanFix"
SCHEME="HanFix"
BUILD_CONFIG="${BUILD_CONFIG:-Release}"

# 빌드 출력 경로
BUILD_DIR="${PROJECT_DIR}/build"
ARCHIVE_PATH="${BUILD_DIR}/${PROJECT_NAME}.xcarchive"
APP_PATH="${BUILD_DIR}/${PROJECT_NAME}.app"
DMG_PATH="${BUILD_DIR}/${PROJECT_NAME}.dmg"

# 버전 정보 (Info.plist에서 추출)
INFO_PLIST="${PROJECT_DIR}/${PROJECT_NAME}/Info.plist"

# ============================================================
# 유틸리티 함수
# ============================================================

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

error() {
    echo "[ERROR] $*" >&2
    exit 1
}

check_env() {
    local var_name="$1"
    if [[ -z "${!var_name:-}" ]]; then
        error "환경 변수 ${var_name}이(가) 설정되지 않았습니다."
    fi
}

# ============================================================
# 환경 변수 로드
# ============================================================

if [[ -f "${PROJECT_DIR}/.env" ]]; then
    log ".env 파일 로드 중..."
    set -a
    source "${PROJECT_DIR}/.env"
    set +a
fi

# ============================================================
# 필수 조건 확인
# ============================================================

log "=== 환경 확인 ==="

# Xcode 확인
if ! command -v xcodebuild &>/dev/null; then
    error "xcodebuild를 찾을 수 없습니다. Xcode를 설치하세요."
fi

# create-dmg 확인 (없으면 hdiutil 사용)
USE_CREATE_DMG=false
if command -v create-dmg &>/dev/null; then
    USE_CREATE_DMG=true
    log "create-dmg 발견 - 사용자 정의 DMG 생성"
else
    log "create-dmg 없음 - hdiutil로 기본 DMG 생성"
    log "  (더 나은 DMG를 원하면: brew install create-dmg)"
fi

# 공증 필요 시 환경 변수 확인
SKIP_NOTARIZE="${SKIP_NOTARIZE:-false}"
if [[ "$SKIP_NOTARIZE" != "true" ]]; then
    check_env "DEVELOPER_ID"
    check_env "TEAM_ID"
    check_env "APPLE_ID"
    check_env "APP_PASSWORD"
    log "코드 서명 및 공증 활성화"
else
    log "공증 건너뛰기 (SKIP_NOTARIZE=true)"
fi

# ============================================================
# 정리
# ============================================================

log "=== 이전 빌드 정리 ==="
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# ============================================================
# 빌드
# ============================================================

log "=== 앱 빌드 (${BUILD_CONFIG}) ==="

xcodebuild \
    -project "${PROJECT_DIR}/${PROJECT_NAME}.xcodeproj" \
    -scheme "$SCHEME" \
    -configuration "$BUILD_CONFIG" \
    -archivePath "$ARCHIVE_PATH" \
    archive \
    | xcpretty || xcodebuild \
    -project "${PROJECT_DIR}/${PROJECT_NAME}.xcodeproj" \
    -scheme "$SCHEME" \
    -configuration "$BUILD_CONFIG" \
    -archivePath "$ARCHIVE_PATH" \
    archive

log "아카이브 완료: $ARCHIVE_PATH"

# 앱 번들 추출
log "=== 앱 번들 추출 ==="
cp -R "${ARCHIVE_PATH}/Products/Applications/${PROJECT_NAME}.app" "$APP_PATH"

# 버전 정보 추출
if [[ -f "${APP_PATH}/Contents/Info.plist" ]]; then
    APP_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "${APP_PATH}/Contents/Info.plist" 2>/dev/null || echo "1.0.0")
    BUILD_NUMBER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "${APP_PATH}/Contents/Info.plist" 2>/dev/null || echo "1")
    log "버전: ${APP_VERSION} (${BUILD_NUMBER})"
    DMG_PATH="${BUILD_DIR}/${PROJECT_NAME}-${APP_VERSION}.dmg"
fi

# ============================================================
# 코드 서명
# ============================================================

if [[ "$SKIP_NOTARIZE" != "true" ]]; then
    log "=== 코드 서명 ==="
    
    # 하드닝 런타임 + 타임스탬프로 서명
    codesign \
        --force \
        --deep \
        --timestamp \
        --options runtime \
        --sign "$DEVELOPER_ID" \
        "$APP_PATH"
    
    # 서명 확인
    log "서명 확인 중..."
    codesign --verify --verbose=2 "$APP_PATH"
    
    # Gatekeeper 검증
    log "Gatekeeper 검증 중..."
    spctl --assess --type execute --verbose=2 "$APP_PATH" || {
        log "경고: Gatekeeper 검증 실패 (공증 전이므로 정상)"
    }
fi

# ============================================================
# DMG 생성
# ============================================================

log "=== DMG 생성 ==="

if [[ "$USE_CREATE_DMG" == "true" ]]; then
    # create-dmg 사용 (예쁜 DMG)
    create-dmg \
        --volname "$PROJECT_NAME" \
        --volicon "${PROJECT_DIR}/${PROJECT_NAME}/Assets.xcassets/AppIcon.appiconset/icon_512x512.png" \
        --window-pos 200 120 \
        --window-size 600 400 \
        --icon-size 100 \
        --icon "$PROJECT_NAME.app" 150 190 \
        --hide-extension "$PROJECT_NAME.app" \
        --app-drop-link 450 190 \
        --no-internet-enable \
        "$DMG_PATH" \
        "$APP_PATH" \
        || {
            log "create-dmg 실패, hdiutil로 폴백"
            USE_CREATE_DMG=false
        }
fi

if [[ "$USE_CREATE_DMG" != "true" ]]; then
    # hdiutil 사용 (기본 DMG)
    TEMP_DMG_DIR="${BUILD_DIR}/dmg_temp"
    mkdir -p "$TEMP_DMG_DIR"
    cp -R "$APP_PATH" "$TEMP_DMG_DIR/"
    ln -s /Applications "$TEMP_DMG_DIR/Applications"
    
    hdiutil create \
        -volname "$PROJECT_NAME" \
        -srcfolder "$TEMP_DMG_DIR" \
        -ov \
        -format UDZO \
        "$DMG_PATH"
    
    rm -rf "$TEMP_DMG_DIR"
fi

log "DMG 생성 완료: $DMG_PATH"

# ============================================================
# DMG 서명
# ============================================================

if [[ "$SKIP_NOTARIZE" != "true" ]]; then
    log "=== DMG 서명 ==="
    codesign \
        --force \
        --timestamp \
        --sign "$DEVELOPER_ID" \
        "$DMG_PATH"
fi

# ============================================================
# 공증
# ============================================================

if [[ "$SKIP_NOTARIZE" != "true" ]]; then
    log "=== Apple 공증 제출 ==="
    
    # notarytool로 공증 제출
    xcrun notarytool submit "$DMG_PATH" \
        --apple-id "$APPLE_ID" \
        --password "$APP_PASSWORD" \
        --team-id "$TEAM_ID" \
        --wait \
        --timeout 30m
    
    # 공증 결과 확인
    NOTARIZE_STATUS=$?
    if [[ $NOTARIZE_STATUS -ne 0 ]]; then
        error "공증 실패. 로그를 확인하세요."
    fi
    
    log "=== 스테이플 ==="
    xcrun stapler staple "$DMG_PATH"
    
    # 스테이플 확인
    xcrun stapler validate "$DMG_PATH"
    log "스테이플 완료"
fi

# ============================================================
# 완료
# ============================================================

log "=== 빌드 완료 ==="
log "DMG 경로: $DMG_PATH"
log "크기: $(du -h "$DMG_PATH" | cut -f1)"

# SHA256 해시 출력 (배포 시 검증용)
log "SHA256: $(shasum -a 256 "$DMG_PATH" | cut -d' ' -f1)"

echo ""
echo "=========================================="
echo "  ${PROJECT_NAME} ${APP_VERSION} 빌드 성공!"
echo "=========================================="
echo ""
echo "배포 파일: $DMG_PATH"
echo ""
