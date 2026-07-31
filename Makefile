INSTALL_DIR ?= $(HOME)/.local/bin
SHARE_DIR   ?= $(HOME)/.local/share/noizu-port-forwards

.PHONY: install test doctor

install:
	@mkdir -p $(INSTALL_DIR) $(SHARE_DIR)
	@install -m 755 bin/cluster-port-forward $(INSTALL_DIR)/cluster-port-forward
	@install -m 644 share/port-forwards.catalog $(SHARE_DIR)/port-forwards.catalog
	@install -m 644 share/hosts.local-dev $(SHARE_DIR)/hosts.local-dev
	@install -m 644 share/Caddyfile.local-dev $(SHARE_DIR)/Caddyfile.local-dev
	@install -m 644 share/local-dev-hosts.md $(SHARE_DIR)/local-dev-hosts.md
	@install -m 644 share/sudoers.d-noizu-local-dev $(SHARE_DIR)/sudoers.d-noizu-local-dev
	@echo "✓ Installed cluster-port-forward → $(INSTALL_DIR)"
	@echo "✓ Share → $(SHARE_DIR)"
	@echo "  sudoers template: $(SHARE_DIR)/sudoers.d-noizu-local-dev"

test:
	@bash -n bin/cluster-port-forward
	@echo "✓ bash -n OK"

doctor:
	@./bin/cluster-port-forward doctor
