VERSION := $(shell grep 'MARKETING_VERSION:' project.yml | head -1 | sed -E 's/.*MARKETING_VERSION: *"?([^"]*)"?.*/\1/')
TAG := v$(VERSION)

.PHONY: release-tag ota
release-tag:
	@if [ -z "$(VERSION)" ]; then \
		echo "error: MARKETING_VERSION not found in project.yml" >&2; \
		exit 1; \
	fi
	@branch="$$(git rev-parse --abbrev-ref HEAD)"; \
	if [ "$$branch" != "main" ]; then \
		echo "error: must be on main to cut a release (current: $$branch)" >&2; \
		exit 1; \
	fi
	@if [ -n "$$(git status --porcelain)" ]; then \
		echo "error: working tree is not clean" >&2; \
		exit 1; \
	fi
	@git fetch origin main --quiet
	@if [ "$$(git rev-parse HEAD)" != "$$(git rev-parse origin/main)" ]; then \
		echo "error: local main is not up to date with origin/main" >&2; \
		exit 1; \
	fi
	@if git rev-parse "$(TAG)" >/dev/null 2>&1; then \
		echo "error: tag $(TAG) already exists" >&2; \
		exit 1; \
	fi
	git tag -a "$(TAG)" -m "Release $(TAG)"
	git push origin "$(TAG)"
	@echo "Pushed tag $(TAG); Xcode Cloud will build and distribute it."

# OTA（Over-The-Air）配布。ipa + manifest.plist + index.html を作り、
# ota.mtkg（miscpi.mtkg の /mnt/storage/ota）へ ssh 配信する。
# 別サーバへ配るときは OTA_URL を渡す（例: make ota OTA_URL=https://example.com）。
ota:
	./Scripts/ota.sh $(OTA_URL)
