SHELL := /bin/bash

.PHONY: serve build clean install help test lint-html check-ascii

help:
	@echo "Available targets:"
	@echo "  make serve   - Serve the site locally at http://localhost:4000"
	@echo "  make build   - Build the site to _site/"
	@echo "  make clean   - Remove the generated _site/ directory"
	@echo "  make install - Install dependencies (Ruby gems)"
	@echo "  make test    - Run lint/quality checks (HTML validity, ASCII-only content)"

serve:
	bundle exec jekyll serve --livereload

build:
	bundle exec jekyll build

clean:
	rm -rf _site/

install:
	bundle install

# Validates the built HTML: broken internal links/anchors, missing images,
# missing alt text, duplicate ids, etc. External links are skipped so the
# check stays fast and deterministic without relying on network access.
lint-html: build
	bundle exec htmlproofer ./_site --disable-external

# Site content must be pure ASCII (no smart quotes, em/en dashes, etc.).
# Checks tracked source files and the rendered output with one shared scan
# function. Uses GNU grep's -P (PCRE) and --exclude-dir/--include, matching
# this project's existing Linux/GNU toolchain assumption (bundler, gems).
check-ascii: build
	@scan() { \
		label=$$1; shift; \
		bad=$$(grep -rIlP "$$@"); \
		if [ -n "$$bad" ]; then \
			echo "Non-ASCII characters found in $$label:"; \
			echo "$$bad"; \
			exit 1; \
		fi; \
	}; \
	scan "source file(s)" --exclude-dir=.git --exclude-dir=vendor --exclude-dir=_site '[^\x00-\x7F]' . && \
	scan "rendered output" --include='*.html' --include='*.css' --include='*.xml' --include='*.txt' --include='*.json' '[^\x00-\x7F]' _site
	@echo "No non-ASCII characters found."


test: lint-html check-ascii
	@echo "All checks passed."

.DEFAULT_GOAL := help
