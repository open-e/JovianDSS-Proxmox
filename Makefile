#DEB_FLAG=0

.PHONY: all, deb, install, uninstall

all: deb
	@echo "The only useful target is 'deb'"

deb:
	@echo "Making deb package"
	$(eval debdir := $(shell mktemp -d))

	@echo "Using tmp dir $(debdir)"
	#DEB_FLAG=1
	make install DESTDIR=$(debdir) DEB_FLAG=1

	install -D -m 0555 ./DEBIAN/control $(debdir)/DEBIAN/control
	install -D -m 0555 ./DEBIAN/postinst $(debdir)/DEBIAN/postinst
	install -D -m 0555 ./DEBIAN/postrm $(debdir)/DEBIAN/postrm

	dpkg-deb --build $(debdir)
	@mv $(debdir).deb ./open-e-joviandss-proxmox-plugin_0.9.5-1.deb
	rm -rf $(debdir)

install:
	@echo "Installing proxmox plugin"
	install -D -m 0644 ./OpenEJovianDSSPlugin.pm $(DESTDIR)/usr/share/perl5/PVE/Storage/Custom/OpenEJovianDSSPlugin.pm
	install -D -m 0644 ./mark-open-e-plugin-as-dynamic.patch $(DESTDIR)/usr/share/open-e/mark-open-e-plugin-as-dynamic.patch

	if [ $(DEB_FLAG) -ne 1 ]; then \
		patch /usr/share/perl5/PVE/Storage/Plugin.pm /usr/share/open-e/mark-open-e-plugin-as-dynamic.patch ; \
	fi
	$(MAKE) -C jdssc install DESTDIR=$(DESTDIR)

uninstall:
	@echo "Cleaning up proxmox plugin"
	rm $(DESTDIR)/usr/share/perl5/PVE/Storage/Custom/OpenEJovianDSSPlugin.pm
	patch -R /usr/share/perl5/PVE/Storage/Plugin.pm /usr/share/open-e/mark-open-e-plugin-as-dynamic.patch
	rm /usr/share/open-e/mark-open-e-plugin-as-dynamic.patch
	$(MAKE) -C jdssc uninstall DESTDIR=$(DESTDIR)
