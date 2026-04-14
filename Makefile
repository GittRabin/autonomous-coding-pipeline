.PHONY: logs restart status run-now uninstall status-all

PROFILE ?= default

SERVICE = pipeline-poller@$(PROFILE).service
TIMER = pipeline-poller@$(PROFILE).timer

logs:
	sudo journalctl -u $(SERVICE) -u $(TIMER) -f

restart:
	sudo systemctl restart $(TIMER)

status:
	sudo systemctl --no-pager status $(TIMER) $(SERVICE)

status-all:
	sudo systemctl list-timers --all 'pipeline-poller@*.timer' --no-pager

run-now:
	sudo systemctl start $(SERVICE)

uninstall:
	sudo systemctl stop $(TIMER) || true
	sudo systemctl disable $(TIMER) || true
	sudo rm -f /etc/rabin/projects/$(PROFILE).env
	sudo rm -rf /etc/systemd/system/$(TIMER).d
	sudo systemctl daemon-reload
	sudo systemctl reset-failed
	@echo "Removed profile $(PROFILE) from pipeline-poller templates."
