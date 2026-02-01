# Aerie task shortcuts

specs:
	@./specs/tools/update_manifest.sh

specs-check:
	@./specs/tools/check_manifest.sh

specs-hooks:
	@./specs/tools/install_hooks.sh

specs-unlock:
	@./specs/tools/unlock_outputs.sh

specs-verify:
	@./specs/tools/check_manifest.sh
	@./specs/tools/install_hooks.sh
