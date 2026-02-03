#
# HanFix Makefile
# macOS NFD→NFC 파일명 자동 변환 앱
#

.PHONY: all build release clean dmg notarize help

# 기본 설정
PROJECT_NAME := HanFix
SCHEME := HanFix
PROJECT := $(PROJECT_NAME).xcodeproj
BUILD_DIR := build

# Xcode 빌드 설정
XCODEBUILD := xcodebuild
XCPRETTY := $(shell command -v xcpretty 2>/dev/null)

ifdef XCPRETTY
	XCODEBUILD_PIPE := | xcpretty
else
	XCODEBUILD_PIPE :=
endif

# ============================================================
# 기본 타겟
# ============================================================

all: build

help:
	@echo ""
	@echo "HanFix 빌드 시스템"
	@echo "=================="
	@echo ""
	@echo "사용 가능한 명령:"
	@echo "  make build      - Debug 빌드"
	@echo "  make release    - Release 빌드"
	@echo "  make clean      - 빌드 결과물 삭제"
	@echo "  make dmg        - 배포용 DMG 생성 (서명 + 공증)"
	@echo "  make dmg-local  - 로컬 테스트용 DMG (서명/공증 없음)"
	@echo "  make open       - Xcode에서 프로젝트 열기"
	@echo "  make run        - 빌드 후 실행"
	@echo "  make test       - 테스트 실행"
	@echo "  make lint       - SwiftLint 실행 (설치 필요)"
	@echo ""
	@echo "환경 변수 (DMG 생성 시 필요):"
	@echo "  DEVELOPER_ID    - Developer ID Application 인증서 이름"
	@echo "  TEAM_ID         - Apple Developer Team ID"
	@echo "  APPLE_ID        - Apple ID 이메일"
	@echo "  APP_PASSWORD    - App-Specific Password"
	@echo ""

# ============================================================
# 빌드
# ============================================================

build:
	@echo "=== Debug 빌드 ==="
	$(XCODEBUILD) \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-configuration Debug \
		-derivedDataPath $(BUILD_DIR)/DerivedData \
		build \
		$(XCODEBUILD_PIPE)
	@echo "빌드 완료: $(BUILD_DIR)/DerivedData/Build/Products/Debug/$(PROJECT_NAME).app"

release:
	@echo "=== Release 빌드 ==="
	$(XCODEBUILD) \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-configuration Release \
		-derivedDataPath $(BUILD_DIR)/DerivedData \
		build \
		$(XCODEBUILD_PIPE)
	@echo "빌드 완료: $(BUILD_DIR)/DerivedData/Build/Products/Release/$(PROJECT_NAME).app"

# ============================================================
# 정리
# ============================================================

clean:
	@echo "=== 빌드 정리 ==="
	rm -rf $(BUILD_DIR)
	$(XCODEBUILD) \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		clean \
		$(XCODEBUILD_PIPE)
	@echo "정리 완료"

# ============================================================
# DMG 생성
# ============================================================

dmg:
	@echo "=== 배포용 DMG 생성 ==="
	./scripts/create-dmg.sh

dmg-local:
	@echo "=== 로컬 테스트용 DMG 생성 ==="
	SKIP_NOTARIZE=true ./scripts/create-dmg.sh

# ============================================================
# 개발 편의
# ============================================================

open:
	@echo "=== Xcode 열기 ==="
	open $(PROJECT)

run: build
	@echo "=== 앱 실행 ==="
	open "$(BUILD_DIR)/DerivedData/Build/Products/Debug/$(PROJECT_NAME).app"

# ============================================================
# 테스트
# ============================================================

test:
	@echo "=== 테스트 실행 ==="
	$(XCODEBUILD) \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-destination 'platform=macOS' \
		test \
		$(XCODEBUILD_PIPE)

# ============================================================
# 코드 품질
# ============================================================

lint:
	@echo "=== SwiftLint ==="
	@if command -v swiftlint &>/dev/null; then \
		swiftlint --config .swiftlint.yml 2>/dev/null || swiftlint; \
	else \
		echo "SwiftLint가 설치되지 않았습니다: brew install swiftlint"; \
	fi

format:
	@echo "=== SwiftFormat ==="
	@if command -v swiftformat &>/dev/null; then \
		swiftformat $(PROJECT_NAME) --config .swiftformat 2>/dev/null || swiftformat $(PROJECT_NAME); \
	else \
		echo "SwiftFormat이 설치되지 않았습니다: brew install swiftformat"; \
	fi

# ============================================================
# 의존성 확인
# ============================================================

check-deps:
	@echo "=== 개발 환경 확인 ==="
	@echo -n "Xcode: " && xcodebuild -version | head -1 || echo "없음"
	@echo -n "xcpretty: " && (xcpretty --version 2>/dev/null || echo "없음 (gem install xcpretty)")
	@echo -n "create-dmg: " && (create-dmg --version 2>/dev/null || echo "없음 (brew install create-dmg)")
	@echo -n "swiftlint: " && (swiftlint version 2>/dev/null || echo "없음 (brew install swiftlint)")
	@echo -n "swiftformat: " && (swiftformat --version 2>/dev/null || echo "없음 (brew install swiftformat)")
