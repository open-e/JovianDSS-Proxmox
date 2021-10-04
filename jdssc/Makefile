install:
	@echo "Installing jdssc tool"
	@find jdssc -type f -exec install -Dm 644 "{}" "/usr/lib/python3/dist-packages/{}" \;
	install -D -m 0645 ./bin/jdssc /usr/local/bin/

uninstall:
	@echo "Cleaning up"
	rm -rvf /tmp/jdssc
	rm /usr/local/bin/jdssc
