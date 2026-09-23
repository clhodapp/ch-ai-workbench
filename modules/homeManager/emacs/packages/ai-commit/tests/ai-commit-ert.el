;;; ai-commit-ert.el --- ERT tests for ai-commit -*- lexical-binding: t -*-
;; SPDX-License-Identifier: MIT
;;; Commentary:
;; Tests for the pure parts: response cleanup, input truncation, and
;; CLI argv construction.  The backends themselves talk to external
;; processes/services and are exercised interactively.
;;; Code:

(require 'ert)
(require 'ai-commit)

(ert-deftest ai-commit-clean-passthrough ()
  (should (equal "feat(lib): Add helper"
                 (ai-commit--clean "feat(lib): Add helper"))))

(ert-deftest ai-commit-clean-trims-whitespace ()
  (should (equal "fix(core): Guard nil input"
                 (ai-commit--clean "\n  fix(core): Guard nil input \n\n"))))

(ert-deftest ai-commit-clean-strips-bare-fence ()
  (should (equal "docs(readme): Clarify setup"
                 (ai-commit--clean "```\ndocs(readme): Clarify setup\n```"))))

(ert-deftest ai-commit-clean-strips-labeled-fence-multiline ()
  (should (equal "feat(x): Subject\n\nBody line."
                 (ai-commit--clean
                  "```text\nfeat(x): Subject\n\nBody line.\n```"))))

(ert-deftest ai-commit-clean-keeps-interior-fences ()
  (should (equal "subject\n```\ninterior\n```\ntail"
                 (ai-commit--clean "subject\n```\ninterior\n```\ntail"))))

(ert-deftest ai-commit-clean-nil-is-empty ()
  (should (equal "" (ai-commit--clean nil))))

(ert-deftest ai-commit-truncate-short-unchanged ()
  (let ((ai-commit-max-input-chars 10))
    (should (equal "short" (ai-commit--truncate "short")))))

(ert-deftest ai-commit-truncate-clips-and-marks ()
  (let ((ai-commit-max-input-chars 4))
    (should (equal "abcd\n[input truncated]"
                   (ai-commit--truncate "abcdefgh")))))

(ert-deftest ai-commit-cli-command-default ()
  (let ((ai-commit-claude-program "claude")
        (ai-commit-claude-model nil)
        (ai-commit-claude-args '("--output-format" "text"))
        (ai-commit-prompt "PROMPT"))
    (should (equal '("claude" "-p" "PROMPT" "--output-format" "text")
                   (ai-commit--cli-command)))))

(ert-deftest ai-commit-cli-command-with-model ()
  (let ((ai-commit-claude-program "claude")
        (ai-commit-claude-model "fable")
        (ai-commit-claude-args '())
        (ai-commit-prompt "PROMPT"))
    (should (equal '("claude" "-p" "PROMPT" "--model" "fable")
                   (ai-commit--cli-command)))))

(provide 'ai-commit-ert)
;;; ai-commit-ert.el ends here
