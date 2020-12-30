PANDOC=pandoc \
			 --from markdown+autolink_bare_uris+simple_tables+table_captions \
			 --lua-filter ./lua-filters/include-code-files/include-code-files.lua \
			 --lua-filter ./lua-filters/include-files/include-files.lua \
			 --lua-filter ./lua-filters/minted/minted.lua \
			 --template template.tex

MD_FILES:=$(wildcard *.md)

all: paper.pdf

%.tex: %.md $(MD_FILES)
	$(PANDOC) -s -t latex --no-highlight -o $@ $<

paper.pdf: paper.tex
	latexmk -pdf -shell-escape paper.tex

paper.html: paper.md
	$(PANDOC) -s -o $@ $<

.PHONY: clean
clean:
	latexmk -c paper >/dev/null 2>&1 || true
	rm -f paper.tex paper.pdf paper.html
