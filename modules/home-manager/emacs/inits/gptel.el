;; SPDX-License-Identifier: MIT
;;; -*- lexical-binding: t -*-
;; init gptel
(eval-when-compile (require 'gptel-request))
(declare-function gptel "gptel")
(declare-function gptel-send "gptel")
(declare-function gptel-menu "gptel-transient")
(declare-function gptel-make-anthropic "gptel-anthropic")
(declare-function gptel-make-openai "gptel-openai")
(declare-function gptel-highlight-mode "gptel")
(declare-function url-hexify-string "url-util")

(defvar ch-emacs-config-gptel--openrouter-backend nil)
(defvar ch-emacs-config-gptel--fireworks-backend nil)

;; OpenRouter: OpenAI-compatible format.
;; Response: {"data": [{"id": "..."}], "has_more": bool}
;; Pagination: ?after=LAST_ID

(defun ch-emacs-config-gptel--fetch-openrouter-page (backend base-url api-key after acc)
  "Fetch one page of OpenRouter models; recurse when has_more is t."
  (let ((url-request-method "GET")
        (url-request-extra-headers
         `(("Authorization" . ,(concat "Bearer " api-key))))
        (page-url (if after
                      (format "%s?after=%s" base-url (url-hexify-string after))
                    base-url)))
    (url-retrieve
     page-url
     (lambda (status)
       (unless (plist-get status :error)
         (goto-char (point-min))
         (when (re-search-forward "\r?\n\r?\n" nil t)
           (condition-case nil
               (let* ((data (json-parse-buffer :object-type 'alist
                                               :array-type 'list))
                      (items (alist-get 'data data))
                      (has-more (eq (alist-get 'has_more data) t))
                      (page-models (delq nil
                                         (mapcar (lambda (item)
                                                   (when-let* ((id (alist-get 'id item)))
                                                     (intern id)))
                                                 items)))
                      (all-models (append acc page-models)))
                 (if (and has-more page-models)
                     (ch-emacs-config-gptel--fetch-openrouter-page
                      backend base-url api-key
                      (symbol-name (car (last page-models)))
                      all-models)
                   (when all-models
                     (setf (gptel-backend-models backend) all-models))))
             (error nil)))))
     nil t t)))

;; Fireworks: REST API format.
;; Response: {"models": [{"name": "accounts/fireworks/models/...",
;;                         "supportsServerless": bool, ...}],
;;            "nextPageToken": "2", "totalSize": 287}
;; Pagination: ?pageToken=TOKEN
;; Only models with supportsServerless=true are usable without deployment.

(defun ch-emacs-config-gptel--fetch-fireworks-page (backend api-key page-token acc)
  "Fetch one page of Fireworks models; recurse while nextPageToken is present."
  (let ((url-request-method "GET")
        (url-request-extra-headers
         `(("Authorization" . ,(concat "Bearer " api-key))))
        (page-url (format "https://api.fireworks.ai/v1/accounts/fireworks/models?pageSize=100%s"
                          (if page-token
                              (format "&pageToken=%s" (url-hexify-string page-token))
                            ""))))
    (url-retrieve
     page-url
     (lambda (status)
       (unless (plist-get status :error)
         (goto-char (point-min))
         (when (re-search-forward "\r?\n\r?\n" nil t)
           (condition-case nil
               (let* ((data (json-parse-buffer :object-type 'alist
                                               :array-type 'list))
                      (next-token (alist-get 'nextPageToken data))
                      (page-models
                       (delq nil
                             (mapcar (lambda (item)
                                       (let ((kind (alist-get 'kind item)))
                                         (when (and (eq (alist-get 'supportsServerless item) t)
                                                    (not (equal kind "FLUMINA_BASE_MODEL"))
                                                    (not (equal kind "EMBEDDING_MODEL"))
                                                    (alist-get 'name item))
                                           (intern (alist-get 'name item)))))
                                     (alist-get 'models data))))
                      (all-models (append acc page-models)))
                 (when all-models
                   (setf (gptel-backend-models backend) all-models))
                 (when (and (stringp next-token) (not (string-empty-p next-token)))
                   (ch-emacs-config-gptel--fetch-fireworks-page
                    backend api-key next-token all-models)))
             (error nil)))))
     nil t t)))

(defun ch-emacs-config-gptel-refresh-models ()
  "Refresh model lists for OpenRouter and Fireworks from their APIs."
  (interactive)
  (when ch-emacs-config-gptel--openrouter-backend
    (let* ((key-fn (gptel-backend-key ch-emacs-config-gptel--openrouter-backend))
           (api-key (when (functionp key-fn)
                      (condition-case nil (funcall key-fn) (error nil)))))
      (when api-key
        (ch-emacs-config-gptel--fetch-openrouter-page
         ch-emacs-config-gptel--openrouter-backend
         "https://openrouter.ai/api/v1/models"
         api-key nil nil))))
  (when ch-emacs-config-gptel--fireworks-backend
    (let* ((key-fn (gptel-backend-key ch-emacs-config-gptel--fireworks-backend))
           (api-key (when (functionp key-fn)
                      (condition-case nil (funcall key-fn) (error nil)))))
      (when api-key
        (ch-emacs-config-gptel--fetch-fireworks-page
         ch-emacs-config-gptel--fireworks-backend api-key nil nil)))))

(use-package gptel
  :demand t

  :commands
  (gptel
   gptel-send
   gptel-menu)

  :config
  (setq gptel-backend
        (gptel-make-anthropic "Claude"
          :stream t
          :key (lambda ()
                 (auth-source-pick-first-password
                  :host "api.anthropic.com"
                  :user "apikey"))))
  (setq gptel-model 'claude-sonnet-4-6)

  (setq ch-emacs-config-gptel--openrouter-backend
        (gptel-make-openai "OpenRouter"
          :host "openrouter.ai"
          :endpoint "/api/v1/chat/completions"
          :stream t
          :key (lambda ()
                 (auth-source-pick-first-password
                  :host "openrouter.ai"
                  :user "apikey"))
          :models '(anthropic/claude-sonnet-4-6
                    openai/gpt-4o
                    google/gemini-2.5-pro
                    deepseek/deepseek-r1)))

  (setq ch-emacs-config-gptel--fireworks-backend
        (gptel-make-openai "Fireworks"
          :host "api.fireworks.ai"
          :endpoint "/inference/v1/chat/completions"
          :stream t
          :key (lambda ()
                 (auth-source-pick-first-password
                  :host "api.fireworks.ai"
                  :user "apikey"))
          :models '(accounts/fireworks/models/deepseek-v4-flash
                    accounts/fireworks/models/deepseek-v4-pro
                    accounts/fireworks/models/kimi-k2p7-code
                    accounts/fireworks/models/minimax-m3
                    accounts/fireworks/models/nemotron-3-ultra-nvfp4)))

  (ch-emacs-config-gptel-refresh-models)

  (add-hook 'gptel-mode-hook #'gptel-highlight-mode)

  (with-eval-after-load 'evil
    (ch/leader-prefix-title "a" "ai")
    (evil-global-set-key 'motion (kbd "<leader> a a") #'gptel)
    (evil-global-set-key 'motion (kbd "<leader> a s") #'gptel-send)
    (evil-global-set-key 'motion (kbd "<leader> a m") #'gptel-menu)))
