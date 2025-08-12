IMAGE_VERSION=$(shell git describe --long --tags)

.PHONY: all, deb, install, uninstall

all: deb
	@echo "The only useful target is 'deb'"

deb:
	@echo "Making deb package"

	$(eval debdir := $(shell mktemp -d))

	@echo "Using tmp dir $(debdir)"
	make install DESTDIR=$(debdir) DEB_FLAG=1

	install -D -m 0555 ./DEBIAN/control $(debdir)/DEBIAN/control
	install -D -m 0555 ./DEBIAN/postinst $(debdir)/DEBIAN/postinst
	install -D -m 0555 ./DEBIAN/prerm $(debdir)/DEBIAN/postrm

	dpkg-deb --build $(debdir)
	@mv $(debdir).deb ./open-e-joviandss-proxmox-plugin-$(IMAGE_VERSION).deb
	@cp ./open-e-joviandss-proxmox-plugin-$(IMAGE_VERSION).deb ./open-e-joviandss-proxmox-plugin-latest.deb
	rm -rf $(debdir)

install:
	@echo "Installing proxmox plugin"
	install -D -m 0644 ./OpenEJovianDSSPlugin.pm $(DESTDIR)/usr/share/perl5/PVE/Storage/Custom/OpenEJovianDSSPlugin.pm
	install -D -m 0644 ./OpenEJovianDSS/Common.pm $(DESTDIR)/usr/share/perl5/OpenEJovianDSS/Common.pm

	$(MAKE) -C jdssc install DESTDIR=$(DESTDIR)

uninstall:
	@echo "Cleaning up proxmox plugin"
	rm $(DESTDIR)/usr/share/perl5/PVE/Storage/Custom/OpenEJovianDSSPlugin.pm
	rm $(DESTDIR)/usr/share/perl5/OpenEJovianDSS/Common.pm
	$(MAKE) -C jdssc uninstall DESTDIR=$(DESTDIR)
