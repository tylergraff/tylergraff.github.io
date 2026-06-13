.PHONY: serve build clean install help

help:
	@echo "Available targets:"
	@echo "  make serve   - Serve the site locally at http://localhost:4000"
	@echo "  make build   - Build the site to _site/"
	@echo "  make clean   - Remove the generated _site/ directory"
	@echo "  make install - Install dependencies (Ruby gems)"

serve:
	jekyll serve --livereload

build:
	jekyll build

clean:
	rm -rf _site/

install:
	bundle install

.DEFAULT_GOAL := help
