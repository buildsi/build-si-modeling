PANDOC=pandoc \
			 --from markdown+autolink_bare_uris+simple_tables+table_captions

FILES_IN_ORDER=outline.md

paper.pdf: $(FILES_IN_ORDER)
	$(PANDOC) -o $@ $<

paper.html: $(FILES_IN_ORDER)
	$(PANDOC) -o $@ $<


