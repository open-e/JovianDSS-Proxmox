LOCAL_BIN=/usr/local/bin
PYTHON_PACKAGE=/usr/lib/python3/dist-packages
PERLDIR=/usr/share/perl5

.PHONY: all, install, uninstall

all: deb
	@echo "The only useful target is 'deb'"

deb:
	@echo "Making deb package"
	dpkg-deb --build deb-test
	dh_clean
	debuild -us -uc -i -b

#SHELL = /bin/bash

install:
	@echo "Installing proxmox plugin"
	install -D -m 0644 ./OpenEJovianDSSPlugin.pm $(PERLDIR)/PVE/Storage/Custom/OpenEJovianDSSPlugin.pm
	$(MAKE) -C jdssc install

uninstall:
	@echo "Cleaning up proxmox plugin"
	rm $(PERLDIR)/PVE/Storage/Custom/OpenEJovianDSSPlugin.pm
	$(MAKE) -C jdssc uninstall


#garbo:
	#install -D -m 0645 jdssc/bin/jdssc /usr/local/bin/
	#`ls -l | awk ' /^d/ { print $NF } '`
	#$(shell chmod +x ${LOCAL_SHARE}/jdssc/jdssc)
	#$(shell ln -n $(LOCAL_SHARE)/jdssc/jdssc $(LOCAL_BIN)/jdssc)
