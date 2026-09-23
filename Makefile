SHELL := /bin/bash

.PHONY: serve build clean install help test lint-html check-ascii resume-pdf

RESUME_PDF := assets/resume/Tyler-Graff-Resume.pdf

help:
	@echo "Available targets:"
	@echo "  make serve       - Serve the site locally at http://localhost:4000"
	@echo "  make build       - Build the site to _site/"
	@echo "  make clean       - Remove the generated _site/ directory"
	@echo "  make install     - Install dependencies (Ruby gems)"
	@echo "  make test        - Run lint/quality checks (HTML validity, ASCII-only content)"
	@echo "  make resume-pdf  - Regenerate $(RESUME_PDF) from the live resume page"

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

# Regenerates the downloadable resume PDF from the live resume page: serves
# the built _site over HTTP (so absolute /assets/... paths resolve, unlike
# file://), prints it with headless Chrome, then strips all metadata
# (title, producer, timestamps, converting user-agent) via qpdf's
# empty-document rebuild trick.
resume-pdf: build
	@python3 -m http.server 8123 --bind 127.0.0.1 --directory _site &>/tmp/resume-pdf-server.log & \
	server_pid=$$!; \
	trap 'kill $$server_pid 2>/dev/null' EXIT; \
	for i in $$(seq 1 20); do \
		python3 -c "import socket; socket.create_connection(('127.0.0.1', 8123), 0.2).close()" 2>/dev/null && break; \
		sleep 0.2; \
	done; \
	google-chrome --headless --disable-gpu --no-sandbox --no-pdf-header-footer \
		--print-to-pdf=/tmp/resume-raw.pdf "http://127.0.0.1:8123/resume/"; \
	qpdf --empty --pages /tmp/resume-raw.pdf 1-z -- "$(RESUME_PDF)"; \
	rm -f /tmp/resume-raw.pdf
	@echo "Wrote $(RESUME_PDF)"

.DEFAULT_GOAL := help
