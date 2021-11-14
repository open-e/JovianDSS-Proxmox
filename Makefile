LOCAL_BIN=$(DESTDIR)/usr/local/bin
PYTHON_PACKAGE=$(DESTDIR)/usr/lib/python3/dist-packages
PERLDIR=$(DESTDIR)/usr/share/perl5

.PHONY: all, install, uninstall

all: deb
	@echo "The only useful target is 'deb'"

deb:
	@echo "Making deb package"
	$(eval debdir := $(shell mktemp -d))

	@echo "Using tmp dir $(debdir)"
	make install DESTDIR=$(debdir)
	
	install -D -m 0555 ./DEBIAN/control $(debdir)/DEBIAN/control
	install -D -m 0555 ./DEBIAN/postinst $(debdir)/DEBIAN/postinst
	install -D -m 0555 ./DEBIAN/postrm $(debdir)/DEBIAN/postrm
	
	dpkg-deb --build $(debdir)
	@mv $(debdir).deb ./open-e-joviandss-proxmox-plugin_0.9.1-1.deb	
	rm -rf $(debdir)

install:
	@echo "Installing proxmox plugin"
	install -D -m 0644 ./OpenEJovianDSSPlugin.pm $(PERLDIR)/PVE/Storage/Custom/OpenEJovianDSSPlugin.pm
	$(MAKE) -C jdssc install DESTDIR=$(DESTDIR)

uninstall:
	@echo "Cleaning up proxmox plugin"
	rm $(PERLDIR)/PVE/Storage/Custom/OpenEJovianDSSPlugin.pm
	$(MAKE) -C jdssc uninstall DESTDIR=$(DESTDIR)
