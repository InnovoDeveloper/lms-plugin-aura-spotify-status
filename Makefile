# Build the distributable LMS plugin zip + the plugin-manager repo.xml (extensions.xml).
# Mirrors the Innovo Pandora plugin build (lms-plugin-pandora).

PLUGIN_NAME     := $(shell sed -n 's,.*<plugin.*name="\([^"]*\)".*,\1,p' misc/repo.xml)

# PLUGIN_VERSION from `git describe` (x.y.z), or overridden by the CI release
# workflow with the pushed tag. Dev builds "0.1.0-4-gabcd" -> "0.1.0+4gabcd" so
# LMS's version comparator sees them as newer than the base.
PLUGIN_VERSION ?= $(shell git describe 2>/dev/null | sed -E 's/^v?([0-9]+\.[0-9]+\.[0-9]+)-([0-9]+)-(g[0-9a-f]+)$$/\1+\2\3/' | sed -E 's/^v//')

GIT_COMMIT_TS   := $(shell git log -1 --format="%at")
GIT_COMMIT_DATE := $(shell env TZ= date -d @$(GIT_COMMIT_TS) '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || env TZ= date -r $(GIT_COMMIT_TS) '+%Y-%m-%dT%H:%M:%S')
PLUGIN_ZIP       = lms-plugin-$(PLUGIN_NAME)-$(PLUGIN_VERSION).zip
PLUGIN_ZIPURL    = https://github.com/InnovoDeveloper/lms-plugin-aura-spotify-status/releases/download/$(PLUGIN_VERSION)/$(PLUGIN_ZIP)

OBJDIR = obj

ZIPEXTRAS += README.md
ZIPEXTRAS += LICENSE

.PHONY: dist
dist:
	rm -Rf $(OBJDIR)
	mkdir -p $(OBJDIR)
	# seed the plugin dir
	tar cf - plugin | (cd $(OBJDIR) && tar xf -)
	-cp $(ZIPEXTRAS) $(OBJDIR)/plugin/ 2>/dev/null || true
	# update install.xml with our version
	m4 -D__VERSION__=$(PLUGIN_VERSION) plugin/install.xml > $(OBJDIR)/plugin/install.xml
	# normalise file times to the git commit date (reproducible zips; best-effort —
	# skip cleanly if the commit date can't be resolved, e.g. shallow/detached CI).
	@if [ -n "$(GIT_COMMIT_DATE)" ]; then \
	  find $(OBJDIR)/plugin -type f | while read f; do \
	    env TZ= touch -d "$(GIT_COMMIT_DATE)" "$$f" 2>/dev/null || true ; \
	  done ; \
	fi
	# zip FLAT (install.xml + files at the zip root — matches the Pandora layout;
	# LMS's plugin-manager reads install.xml at the root and creates the plugin dir
	# from the <module> name itself).
	(cd $(OBJDIR)/plugin && find . -type f | sort | zip -X --names-stdin ../plugin.zip)
	# create the distribution
	mkdir -p $(OBJDIR)/dist
	cp $(OBJDIR)/plugin.zip $(OBJDIR)/dist/$(PLUGIN_ZIP)
	m4 -D__VERSION__=$(PLUGIN_VERSION)                                \
	   -D__ZIPURL__=$(PLUGIN_ZIPURL)                                  \
	   -D__SHA__=`shasum $(OBJDIR)/dist/$(PLUGIN_ZIP) | cut -d\  -f1` \
	   misc/repo.xml > $(OBJDIR)/dist/extensions.xml

.PHONY: clean
clean:
	rm -Rf $(OBJDIR)
