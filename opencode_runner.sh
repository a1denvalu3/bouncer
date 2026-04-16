#!/bin/bash
gh auth setup-git
export OPENCODE_AUTO_CONFIRM=true
export OPENCODE_PERMISSION='{"external_directory": {"*": "allow"}}'
opencode run -m "$OPENCODE_MODEL" "$(cat .opencode_prompt)"
