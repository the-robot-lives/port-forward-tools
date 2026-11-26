INSTALL_DIR ?= $(HOME)/.local/bin
SHARE_DIR   ?= $(HOME)/.local/share/noizu-port-forwards

.PHONY: install uninstall test doctor

install:
	@mkdir -p $(INSTALL_DIR) $(SHARE_DIR) $(SHARE_DIR)/profiles
	@install -m 755 bin/cluster-port-forward $(INSTALL_DIR)/cluster-port-forward
	@install -m 755 bin/tunnel-watchdog $(INSTALL_DIR)/tunnel-watchdog
	@install -m 755 bin/db-watchdog $(INSTALL_DIR)/db-watchdog
	@install -m 755 bin/valkey-watchdog $(INSTALL_DIR)/valkey-watchdog
	@install -m 755 bin/weaviate-watchdog $(INSTALL_DIR)/weaviate-watchdog
	@install -m 644 share/port-forwards.catalog $(SHARE_DIR)/port-forwards.catalog
	@install -m 644 share/hosts.local-dev $(SHARE_DIR)/hosts.local-dev
	@install -m 644 share/Caddyfile.local-dev $(SHARE_DIR)/Caddyfile.local-dev
	@install -m 644 share/local-dev-hosts.md $(SHARE_DIR)/local-dev-hosts.md
	@install -m 644 share/sudoers.d-noizu-local-dev $(SHARE_DIR)/sudoers.d-noizu-local-dev
	@install -m 644 share/profiles/noizu.yaml.example $(SHARE_DIR)/profiles/noizu.yaml.example
	@mkdir -p $(SHARE_DIR)/web
	@install -m 644 share/web/index.html $(SHARE_DIR)/web/index.html
	@install -m 755 share/web/server.py $(SHARE_DIR)/web/server.py
	@mkdir -p $(HOME)/.config/tunnel-watcher
	@if [ ! -f $(HOME)/.config/tunnel-watcher/noizu.yaml ]; then \
		install -m 644 share/profiles/noizu.yaml.example $(HOME)/.config/tunnel-watcher/noizu.yaml; \
		echo "✓ Seeded tunnel profile → $(HOME)/.config/tunnel-watcher/noizu.yaml"; \
	else \
		echo "  tunnel profile exists, left untouched: $(HOME)/.config/tunnel-watcher/noizu.yaml"; \
	fi
	@echo "✓ Installed cluster-port-forward → $(INSTALL_DIR)"
	@echo "✓ Installed tunnel-watchdog + db/valkey/weaviate-watchdog → $(INSTALL_DIR)"
	@echo "✓ Share → $(SHARE_DIR)"
	@echo "  sudoers template: $(SHARE_DIR)/sudoers.d-noizu-local-dev"

uninstall:
	@rm -f $(INSTALL_DIR)/tunnel-watchdog $(INSTALL_DIR)/db-watchdog $(INSTALL_DIR)/valkey-watchdog $(INSTALL_DIR)/weaviate-watchdog
	@echo "✓ Removed tunnel-watchdog + db/valkey/weaviate-watchdog from $(INSTALL_DIR)"

test:
	@bash -n bin/cluster-port-forward
	@bash -n bin/tunnel-watchdog bin/db-watchdog bin/valkey-watchdog bin/weaviate-watchdog
	@echo "✓ bash -n OK"
	@bash test/run-tests.sh
	@bash test/watchdog-tests.sh

doctor:
	@./bin/cluster-port-forward doctor
