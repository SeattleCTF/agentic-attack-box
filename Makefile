.PHONY: all aictf install clean

all: aictf

aictf:
	mkdir -p bin
	echo ""
	echo "Assembling script"
	echo ""
	echo "Header:"
	echo "#!/usr/bin/env bash" > bin/aictf
	echo "# aictf - Agentic Attack Box Manager" >> bin/aictf
	echo "_AICFT_BUNDLED=1" >> bin/aictf
	tail -n +2 src/header.sh >> bin/aictf
	echo ""
	echo "# src/utils.sh" >> bin/aictf
	echo "# ------------" >> bin/aictf
	cat src/utils.sh >> bin/aictf
	echo ""
	echo "# src/config.sh" >> bin/aictf
	echo "# ------------" >> bin/aictf
	cat src/config.sh >> bin/aictf
	echo ""
	echo "# src/list.sh" >> bin/aictf
	echo "# ------------" >> bin/aictf
	cat src/list.sh >> bin/aictf
	echo ""
	echo "# src/aws.sh" >> bin/aictf
	echo "# ------------" >> bin/aictf
	cat src/aws.sh >> bin/aictf
	echo ""
	echo "# src/main.sh" >> bin/aictf
	echo "# ------------" >> bin/aictf
	cat src/main.sh >> bin/aictf
	
	chmod +x bin/aictf

install: aictf
	mkdir -p $(HOME)/.local/bin
	cp bin/aictf $(HOME)/.local/bin/aictf
	chmod +x $(HOME)/.local/bin/aictf

clean:
	rm -rf bin
