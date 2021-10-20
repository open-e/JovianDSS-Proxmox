LOCAL_BIN=$(DESTDIR)/usr/local/bin
PYTHON_PACKAGE=$(DESTDIR)/usr/lib/python3/dist-packages

install:
	@echo "Installing jdssc tool"
	@find jdssc -type f -exec install -Dm 644 "{}" "$(PYTHON_PACKAGE)/{}" \;
	install -D -m 0645 ./bin/jdssc $(LOCAL_BIN)/jdssc

uninstall:
	@echo "Cleaning up"
	rm $(LOCAL_BIN)/jdssc
	rm -rvf $(PYTHON_PACKAGE)/jdssc
