# Build and sideload the Roku channel.
#
#   make                                     build out/roku-onvif-cameras.zip
#   make install ROKU_IP=192.168.1.20 ROKU_PASS=<developer password>
#   make lint / make test                    need `npm install` first

APP := roku-onvif-cameras
ZIP := out/$(APP).zip
SOURCES := manifest $(shell find source components images -type f)

.PHONY: all install lint test clean

all: $(ZIP)

$(ZIP): $(SOURCES)
	@mkdir -p out
	@rm -f $@
	zip -qr $@ manifest source components images
	@echo "Built $@"

install: $(ZIP)
	@test -n "$(ROKU_IP)" || { echo "Usage: make install ROKU_IP=<roku ip> ROKU_PASS=<developer password>"; exit 1; }
	curl --fail --silent --show-error --digest --user "rokudev:$(ROKU_PASS)" \
		-F "mysubmit=Install" -F "archive=@$(ZIP)" -F "passwd=" \
		-o out/install-response.html "http://$(ROKU_IP)/plugin_install"
	@echo "Uploaded to $(ROKU_IP). The channel starts on the TV (an unchanged zip is not reinstalled)."

lint:
	npm run lint

test:
	npm test

clean:
	rm -rf out
