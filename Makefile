SHARE=/usr/share
PERLDIR=/perl5

.PHONY: all, install

all: deb 
	@echo "The only useful target is 'deb'"

deb:
	@echo "Making deb package"
	dpkg-deb --build deb-test
	dh_clean
	debuild -us -uc -i -b

install:
	@echo "Installing"
	install -D -m 0644 ./OpenEJovianDSSPlugin.pm ${SHARE}$(PERLDIR)/PVE/Storage/Custom/OpenEJovianDSSPlugin.pm
	$(shell find ./jdssc -type f -exec  install -Dm 644 "{}" "${SHARE}/{}" \;)
	$(shell chmod +x ${SHARE}/jdssc/jdssc)
	$(shell ln -s $(SHARE)/jdssc/jdssc /usr/bin/jdssc)

uninstall:
	@echo "Cleaning up"
	rm ${SHARE}$(PERLDIR)/PVE/Storage/Custom/OpenEJovianDSSPlugin.pm
	rm -rvf ${SHARE}/jdssc
	rm /usr/bin/jdssc
