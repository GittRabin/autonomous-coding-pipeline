.PHONY: logs restart status run-now uninstall

logs:
	sudo journalctl -u pipeline-poller.service -u pipeline-poller.timer -f

restart:
	sudo systemctl restart pipeline-poller.timer

status:
	sudo systemctl --no-pager status pipeline-poller.timer pipeline-poller.service

run-now:
	sudo systemctl start pipeline-poller.service

uninstall:
	sudo systemctl stop pipeline-poller.timer || true
	sudo systemctl disable pipeline-poller.timer || true
	sudo rm -f /etc/systemd/system/pipeline-poller.service /etc/systemd/system/pipeline-poller.timer
	sudo systemctl daemon-reload
	sudo systemctl reset-failed
	@echo "Uninstalled pipeline-poller timer and service."
