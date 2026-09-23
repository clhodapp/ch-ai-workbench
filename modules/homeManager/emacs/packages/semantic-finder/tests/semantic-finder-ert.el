;;; semantic-finder-ert.el --- ERT tests for semantic-finder -*- lexical-binding: t -*-
;; SPDX-License-Identifier: MIT
;;; Commentary:
;; Tests for everything that does not need a live embedding server:
;; slicing, eligibility, staleness, response parsing, cosine ranking,
;; the on-demand indexing policy (mocked requests), and candidate
;; naming.  The HTTP layer itself is exercised against the real
;; socket-activated service interactively.
;;; Code:

(require 'ert)
(require 'semantic-finder)

(defmacro semantic-finder-test--with-buffer (name content &rest body)
  "Run BODY with a live buffer NAME containing CONTENT bound to `buf'."
  (declare (indent 2))
  `(let ((buf (generate-new-buffer ,name)))
     (unwind-protect
         (progn
           (with-current-buffer buf (insert ,content))
           ,@body)
       (kill-buffer buf))))

(defmacro semantic-finder-test--with-table (&rest body)
  "Run BODY against a fresh, empty memo table, with the model cache
freshly holding just the base model (so nothing asks the network)."
  `(let ((semantic-finder--table (make-hash-table :test #'eq))
         (semantic-finder--models
          (cons (current-time) (list semantic-finder-base-model)))
         (semantic-finder--models-refresh nil))
     ,@body))

;;; Slicing

(ert-deftest semantic-finder-clip-string ()
  (let ((semantic-finder-max-chars 90))
    (should (equal "short" (semantic-finder-clip "short")))
    (let ((clipped (semantic-finder-clip
                    (concat (make-string 300 ?h)
                            (make-string 300 ?m)
                            (make-string 300 ?t)))))
      (should (string-prefix-p (make-string 30 ?h) clipped))
      (should (string-suffix-p (make-string 60 ?t) clipped))
      (should (string-search "[…]" clipped))
      (should (not (string-search "mm" clipped))))))

(ert-deftest semantic-finder-text-small-buffer-whole ()
  (semantic-finder-test--with-buffer "sf-small" "hello scrollback"
    (should (equal (concat (format semantic-finder-document-prefix
                                   (buffer-name buf))
                           "hello scrollback")
                   (semantic-finder--buffer-text buf)))))

(ert-deftest semantic-finder-text-large-buffer-head-and-tail ()
  (semantic-finder-test--with-buffer "sf-large"
      (concat (make-string 300 ?h) (make-string 300 ?m) (make-string 300 ?t))
    (let* ((semantic-finder-max-chars 90)
           (text (semantic-finder--buffer-text buf)))
      ;; prefix + head third + ellipsis + tail two-thirds, middle dropped
      (should (string-prefix-p (concat (format semantic-finder-document-prefix
                                               (buffer-name buf))
                                       (make-string 30 ?h))
                               text))
      (should (string-suffix-p (make-string 60 ?t) text))
      (should (string-search "[…]" text))
      (should (not (string-search "mm" text))))))

;;; Chunking

(ert-deftest semantic-finder-chunk-whole-when-it-fits ()
  (should (equal '("short") (semantic-finder-chunk "short" 40)))
  (should (equal '("any length at all") (semantic-finder-chunk "any length at all" nil))))

(ert-deftest semantic-finder-chunk-repeats-head-and-covers-the-rest ()
  "Every chunk fits the budget and opens with the text's head; the
first runs straight on, later ones mark the gap; the windows after the
head cover the rest exactly once."
  (let* ((semantic-finder-chunk-head-chars 10)
         (text (concat (make-string 10 ?h) (make-string 90 ?b)))
         (chunks (semantic-finder-chunk text 40)))
    (should (> (length chunks) 1))
    (dolist (chunk chunks)
      (should (<= (length chunk) 40))
      (should (string-prefix-p (make-string 10 ?h) chunk)))
    (should-not (string-search "[…]" (car chunks)))
    (dolist (chunk (cdr chunks))
      (should (string-search "[…]" chunk)))
    (should (equal (make-string 90 ?b)
                   (mapconcat (lambda (chunk)
                                (replace-regexp-in-string
                                 "\\`h+\\(\n\\[…\\]\n\\)?" "" chunk))
                              chunks "")))))

(ert-deftest semantic-finder-chunk-head-capped-at-a-third ()
  (let* ((semantic-finder-chunk-head-chars 1000)
         (chunks (semantic-finder-chunk (make-string 200 ?x) 30)))
    (dolist (chunk chunks)
      (should (<= (length chunk) 30)))))

(ert-deftest semantic-finder-buffer-texts-follow-the-model-cap ()
  "A buffer is sent whole to a model with no reported cap and in
prefixed chunks to one whose cap it exceeds."
  (let ((semantic-finder-chars-per-token 1)
        (semantic-finder-chunk-reserve-chars 0)
        (semantic-finder-chunk-head-chars 10)
        (semantic-finder--models
         (cons (current-time) '(("capped" . 60) "uncapped")))
        (semantic-finder--models-refresh nil))
    (semantic-finder-test--with-buffer "sf-chunks" (make-string 100 ?c)
      (progn
        (should (= 60 (semantic-finder--model-max-tokens "capped")))
        (should-not (semantic-finder--model-max-tokens "uncapped"))
        (should (equal '("capped" "uncapped")
                       (semantic-finder--available-models)))
        (should (equal (list (semantic-finder--buffer-text buf))
                       (semantic-finder--buffer-texts buf "uncapped")))
        (let ((texts (semantic-finder--buffer-texts buf "capped"))
              (prefix (format semantic-finder-document-prefix
                              (buffer-name buf))))
          (should (> (length texts) 1))
          (dolist (text texts)
            (should (string-prefix-p (concat prefix (make-string 10 ?c))
                                     text))))))))

(ert-deftest semantic-finder-pack ()
  (should (equal [1.0] (semantic-finder--pack (list [1.0]))))
  (should (equal (list [1.0] [2.0]) (semantic-finder--pack (list [1.0] [2.0])))))

;;; Eligibility and staleness

(ert-deftest semantic-finder-eligibility ()
  (semantic-finder-test--with-buffer "sf-eligible" "content"
    (should (semantic-finder--eligible-p buf)))
  (semantic-finder-test--with-buffer " sf-internal" "content"
    (should-not (semantic-finder--eligible-p buf)))
  (semantic-finder-test--with-buffer "sf-empty" ""
    (should-not (semantic-finder--eligible-p buf)))
  (let ((dead (generate-new-buffer "sf-dead")))
    (kill-buffer dead)
    (should-not (semantic-finder--eligible-p dead))))

(ert-deftest semantic-finder-staleness-tracks-modification-tick ()
  (semantic-finder-test--with-table
   (semantic-finder-test--with-buffer "sf-stale" "v1"
     (should (semantic-finder--stale-p buf))
     (semantic-finder--put buf semantic-finder-base-model
                           (buffer-chars-modified-tick buf) [1.0])
     (should-not (semantic-finder--stale-p buf))
     (with-current-buffer buf (insert " v2"))
     (should (semantic-finder--stale-p buf)))))

(ert-deftest semantic-finder-entries-are-per-model ()
  "Each model's vector has its own tick; refreshing one leaves the other."
  (semantic-finder-test--with-table
   (semantic-finder-test--with-buffer "sf-models" "v1"
     (let ((tick (buffer-chars-modified-tick buf)))
       (semantic-finder--put buf "small" tick [1.0])
       (should (semantic-finder--stale-p buf "large"))
       (should-not (semantic-finder--stale-p buf "small"))
       (semantic-finder--put buf "large" tick [2.0])
       (should (equal [1.0] (cdr (semantic-finder--entry buf "small"))))
       (should (equal [2.0] (cdr (semantic-finder--entry buf "large"))))
       (semantic-finder--put buf "small" tick [3.0])
       (should (equal [3.0] (cdr (semantic-finder--entry buf "small"))))
       (should (equal [2.0] (cdr (semantic-finder--entry buf "large"))))))))

(ert-deftest semantic-finder-query-model-follows-availability ()
  "The upgrade model ranks while the cache lists it, the base model
otherwise; a stale cache still answers as it stands and only
schedules one asynchronous refresh."
  (let ((semantic-finder-base-model "small")
        (semantic-finder-upgrade-model "large")
        (semantic-finder--models (cons (current-time) '("small")))
        (semantic-finder--models-refresh nil)
        (requests nil))
    (cl-letf (((symbol-function 'url-retrieve)
               (lambda (url &rest _) (push url requests) nil)))
      (should (equal "small" (semantic-finder--query-model)))
      (should-not requests)
      (setq semantic-finder--models (cons (current-time) '("small" "large")))
      (should (equal "large" (semantic-finder--query-model)))
      (let ((semantic-finder-upgrade-model nil))
        (should (equal "small" (semantic-finder--query-model))))
      ;; stale: the old answer still ranks, one refresh goes out, and a
      ;; second call does not stack another while it is outstanding
      (setq semantic-finder--models
            (cons (time-subtract (current-time) 120) '("small" "large")))
      (should (equal "large" (semantic-finder--query-model)))
      (should (= 1 (length requests)))
      (should (equal "large" (semantic-finder--query-model)))
      (should (= 1 (length requests))))))

(ert-deftest semantic-finder-scan-queues-base-before-upgrade ()
  "With the upgrade available, stale buffers are queued for the base
model first, then for the upgrade; without it, only for the base."
  (let ((semantic-finder-base-model "small")
        (semantic-finder-upgrade-model "large"))
    (semantic-finder-test--with-table
     (semantic-finder-test--with-buffer "sf-queue" "content"
       (cl-letf (((symbol-function 'semantic-finder--eligible-p)
                  (lambda (b) (eq b buf))))
         (semantic-finder--scan)
         (should (equal (list (cons buf "small")) semantic-finder--queue))
         (setq semantic-finder--models
               (cons (current-time) '("small" "large")))
         (semantic-finder--scan)
         (should (equal (list (cons buf "small") (cons buf "large"))
                        semantic-finder--queue))
         (semantic-finder--put buf "small" (buffer-chars-modified-tick buf) [1.0])
         (semantic-finder--scan)
         (should (equal (list (cons buf "large")) semantic-finder--queue)))))))

(ert-deftest semantic-finder-payload-names-the-model ()
  (let ((payload (semantic-finder--payload '("x") "small")))
    (should (string-search "\"model\":\"small\"" payload)))
  (should-not (string-search "model" (semantic-finder--payload '("x") nil))))

;;; Payload scrubbing

(ert-deftest semantic-finder-scrub-replaces-raw-bytes ()
  "Undecoded bytes (terminal scrollback, jsonrpc event logs) would
make `json-serialize' reject the whole payload."
  (let ((dirty (concat "log line " (string-to-multibyte "\xc3") " tail")))
    (should-error (json-serialize (list :input (vector dirty))))
    (should (equal "log line � tail" (semantic-finder--scrub dirty)))))

(ert-deftest semantic-finder-scrub-decodes-unibyte ()
  (should (equal "naïve"
                 (semantic-finder--scrub
                  (encode-coding-string "naïve" 'utf-8)))))

(ert-deftest semantic-finder-payload-survives-raw-bytes ()
  (semantic-finder-test--with-buffer "sf-raw" "boot log: "
    (with-current-buffer buf
      (insert (string-to-multibyte "\xff\xfe")))
    (should (stringp (semantic-finder--payload
                      (list (semantic-finder--buffer-text buf)))))))

;;; Response parsing

(ert-deftest semantic-finder-parse-response-orders-by-index ()
  (with-temp-buffer
    (insert "HTTP/1.1 200 OK\n"
            "Content-Type: application/json\n"
            "\n"
            "{\"data\":[{\"index\":1,\"embedding\":[3.0,4.0]},"
            "{\"index\":0,\"embedding\":[1.0,2.0]}]}")
    (should (equal '([1.0 2.0] [3.0 4.0])
                   (semantic-finder--parse-response)))))

(ert-deftest semantic-finder-parse-response-nil-on-garbage ()
  (with-temp-buffer
    (insert "HTTP/1.1 500 Internal Server Error\n\n{\"error\":\"boom\"}")
    (should-not (semantic-finder--parse-response)))
  (with-temp-buffer
    (insert "not even http")
    (should-not (semantic-finder--parse-response))))

;;; Non-blocking model cache

(ert-deftest semantic-finder-model-entries-never-block ()
  "A stale cache still answers as it stands; the refresh goes out
asynchronously, at most one at a time."
  (let ((semantic-finder--models
         (cons (time-subtract (current-time) 120) '(("m" . 64))))
        (semantic-finder--models-refresh nil)
        (requests nil))
    (cl-letf (((symbol-function 'url-retrieve)
               (lambda (url &rest _) (push url requests) nil)))
      (should (equal '(("m" . 64)) (semantic-finder--model-entries)))
      (should (= 1 (length requests)))
      (should (string-suffix-p "/v1/models" (car requests)))
      (should (equal '(("m" . 64)) (semantic-finder--model-entries)))
      (should (= 1 (length requests))))))

(ert-deftest semantic-finder-refresh-models-parses-the-answer ()
  "The refresh callback fills the cache from the response buffer and
frees the refresh slot."
  (let ((semantic-finder--models nil)
        (semantic-finder--models-refresh nil)
        callback)
    (cl-letf (((symbol-function 'url-retrieve)
               (lambda (_url cb &rest _) (setq callback cb) nil)))
      (semantic-finder--refresh-models))
    (should callback)
    (should semantic-finder--models-refresh)
    (with-temp-buffer
      (insert "HTTP/1.1 200 OK\n"
              "Content-Type: application/json\n"
              "\n"
              "{\"data\":[{\"id\":\"m\",\"max_tokens\":64}]}")
      (funcall callback nil))
    (should (equal '(("m" . 64)) (cdr semantic-finder--models)))
    (should-not semantic-finder--models-refresh)))

(ert-deftest semantic-finder-refresh-failure-caches-empty ()
  "A refresh that cannot even connect caches an empty answer, and the
drip declines to embed while the cache is empty."
  (let ((semantic-finder--models nil)
        (semantic-finder--models-refresh nil)
        (semantic-finder--inflight nil)
        (semantic-finder--backoff-until nil))
    (cl-letf (((symbol-function 'url-retrieve)
               (lambda (&rest _) (error "refused"))))
      (semantic-finder-test--with-buffer "sf-down" "content"
        (let ((semantic-finder--queue (list (cons buf "m"))))
          (semantic-finder--drip)
          (should (consp semantic-finder--models))
          (should-not (cdr semantic-finder--models))
          (should-not semantic-finder--inflight))))))

(ert-deftest semantic-finder-drip-reaps-a-lost-request ()
  "An embed request older than the timeout is treated as failed: the
flag clears and the indexer backs off."
  (let ((semantic-finder--inflight
         (list (time-subtract (current-time)
                              (* 2 semantic-finder-request-timeout))))
        (semantic-finder--backoff-until nil)
        (semantic-finder--queue nil))
    (semantic-finder--drip)
    (should-not semantic-finder--inflight)
    (should (semantic-finder--backing-off-p))))

;;; Cosine

(ert-deftest semantic-finder-cosine ()
  (should (= 1.0 (semantic-finder--cosine [1.0 0.0] [2.0 0.0])))
  (should (= 0.0 (semantic-finder--cosine [1.0 0.0] [0.0 5.0])))
  (should (= -1.0 (semantic-finder--cosine [1.0 0.0] [-3.0 0.0])))
  (should (= 0.0 (semantic-finder--cosine [0.0 0.0] [1.0 1.0]))))

;;; Indexing policy + ranking (mocked requests)

(defun semantic-finder-test--mock-request (vectors-by-text)
  "`semantic-finder-embed' mock keyed by `string-search' over the text.
VECTORS-BY-TEXT is ((SUBSTRING . VECTOR) ...); each requested text
must match exactly one entry."
  (lambda (texts &optional _model)
    (mapcar (lambda (text)
              (let ((hits (seq-filter (lambda (pair)
                                        (string-search (car pair) text))
                                      vectors-by-text)))
                (unless (= 1 (length hits))
                  (error "ambiguous mock for %S" text))
                (cdar hits)))
            texts)))

(ert-deftest semantic-finder-ranked-orders-by-similarity ()
  (semantic-finder-test--with-table
   (semantic-finder-test--with-buffer "sf-hash" "the build died: hash mismatch"
     (let ((buf-hash buf))
       (semantic-finder-test--with-buffer "sf-media" "jellyfin transcode settings"
         (let ((buf-media buf))
           (cl-letf (((symbol-function 'semantic-finder-embed)
                      (semantic-finder-test--mock-request
                       '(("hash mismatch" . [1.0 0.0])
                         ("jellyfin" . [0.0 1.0])
                         ("query about the failing build" . [0.9 0.1]))))
                     ;; zero anchors: subtraction is a no-op here
                     ((symbol-function 'semantic-finder--anchors)
                      (lambda (_doc _query &optional _model) (cons [0.0 0.0] [0.0 0.0])))
                     ((symbol-function 'semantic-finder--eligible-p)
                      (lambda (b) (memq b (list buf-hash buf-media)))))
             (let ((ranked (semantic-finder--ranked
                            "query about the failing build" nil)))
               (should (equal (list buf-hash buf-media)
                              (mapcar #'car ranked)))
               (should (> (cdr (car ranked)) (cdr (cadr ranked))))))))))))

(ert-deftest semantic-finder-subtract ()
  (should (equal [0.5 -0.5] (semantic-finder--subtract [1.0 0.0] [0.5 0.5]))))

(ert-deftest semantic-finder-score-takes-the-best-chunk ()
  "A chunked document scores as its best chunk, not their average."
  (let ((query [1.0 0.0])
        (anchor [0.0 0.0]))
    (should (= 1.0 (semantic-finder--score query [1.0 0.0] anchor)))
    (should (= 1.0 (semantic-finder--score query (list [0.0 1.0] [1.0 0.0]) anchor)))
    (should (= 0.0 (semantic-finder--score query (list [0.0 1.0] [0.0 2.0]) anchor)))))

(ert-deftest semantic-finder-rank-accepts-chunked-entries ()
  (cl-letf (((symbol-function 'semantic-finder-embed)
             (lambda (_texts &optional _model) (list [1.0 0.0])))
            ((symbol-function 'semantic-finder--anchors)
             (lambda (_doc _query &optional _model) (cons [0.0 0.0] [0.0 0.0]))))
    (should (equal '((chunked . 1.0) (plain . 0.0))
                   (semantic-finder-rank "q"
                                         (list (cons 'plain [0.0 1.0])
                                               (cons 'chunked (list [0.0 1.0] [1.0 0.0])))
                                         "doc: " "query: ")))))

(ert-deftest semantic-finder-ensure-index-regroups-chunks ()
  "One request carries every chunk of every missing buffer, and each
buffer gets back exactly its own vectors."
  (let ((semantic-finder-chars-per-token 1)
        (semantic-finder-chunk-reserve-chars 0)
        (semantic-finder-chunk-head-chars 10))
    (semantic-finder-test--with-table
     (semantic-finder-test--with-buffer "sf-long" (make-string 100 ?l)
       (let ((buf-long buf))
         (semantic-finder-test--with-buffer "sf-short" "short"
           (let ((buf-short buf)
                 (model semantic-finder-base-model)
                 (requests 0))
             (setq semantic-finder--models
                   (cons (current-time) (list (cons model 60))))
             (cl-letf (((symbol-function 'semantic-finder-embed)
                        (lambda (texts &optional _model)
                          (setq requests (1+ requests))
                          (mapcar (lambda (text) (vector (float (length text))))
                                  texts)))
                       ((symbol-function 'semantic-finder--eligible-p)
                        (lambda (b) (memq b (list buf-long buf-short)))))
               (semantic-finder--ensure-index nil)
               (should (= 1 requests))
               (let ((long (cdr (semantic-finder--entry buf-long model)))
                     (short (cdr (semantic-finder--entry buf-short model))))
                 (should (listp long))
                 (should (= (length (semantic-finder--buffer-texts buf-long model))
                            (length long)))
                 (should (vectorp short))
                 (should (= (length (semantic-finder--buffer-text buf-short))
                            (aref short 0))))))))))))

(ert-deftest semantic-finder-anchors-cached-per-configuration ()
  "The boilerplate anchors are embedded once per endpoint and prefix
pair; a different pair (another finder's prefixes) caches separately."
  (let ((semantic-finder--anchor-cache (make-hash-table :test #'equal))
        (requests 0))
    (cl-letf (((symbol-function 'semantic-finder-embed)
               (lambda (texts &optional _model)
                 (setq requests (1+ requests))
                 (mapcar (lambda (_) [1.0 0.0]) texts))))
      (should (equal (cons [1.0 0.0] [1.0 0.0])
                     (semantic-finder--anchors "doc: " "query: ")))
      (semantic-finder--anchors "doc: " "query: ")
      (should (= 1 requests))
      (semantic-finder--anchors "doc: " "different: ")
      (should (= 2 requests))
      (semantic-finder--anchors "doc: " "query: ")
      (should (= 2 requests))
      ;; another model embeds its own anchors
      (semantic-finder--anchors "doc: " "query: " "other-model")
      (should (= 3 requests)))))

(ert-deftest semantic-finder-ranked-anchors-out-boilerplate-hub ()
  "A document that is mostly boilerplate (high raw cosine to every
query) collapses onto the document anchor and stops outranking real
matches; its residual is ~zero."
  (semantic-finder-test--with-table
   (semantic-finder-test--with-buffer "sf-match" "actual build failure text"
     (let ((buf-match buf))
       (semantic-finder-test--with-buffer "sf-hub" "spagetti"
         (let ((buf-hub buf))
           (semantic-finder-test--with-buffer "sf-other" "unrelated media notes"
             (let ((buf-other buf))
               ;; Third component = the boilerplate direction; the hub is
               ;; nothing but it.  Raw cosine to the query: match 1.0,
               ;; hub 0.707, other 0.39 — the hub beats a real document.
               ;; Anchor-subtracted, the hub is the zero vector.
               (cl-letf (((symbol-function 'semantic-finder-embed)
                          (semantic-finder-test--mock-request
                           '(("build failure" . [1.0 0.0 1.0])
                             ("spagetti" . [0.0 0.0 1.0])
                             ("media notes" . [-0.2 1.0 1.0])
                             ("looking for the failed build" . [1.0 0.0 1.0]))))
                         ((symbol-function 'semantic-finder--anchors)
                          (lambda (_doc _query &optional _model)
                            (cons [0.0 0.0 1.0] [0.0 0.0 1.0])))
                         ((symbol-function 'semantic-finder--eligible-p)
                          (lambda (b) (memq b (list buf-match buf-hub buf-other)))))
                 (let* ((ranked (semantic-finder--ranked
                                 "looking for the failed build" nil))
                        (scores (mapcar #'cdr ranked)))
                   (should (equal (list buf-match buf-hub buf-other)
                                  (mapcar #'car ranked)))
                   (should (< (abs (- 1.0 (nth 0 scores))) 1e-6))
                   (should (< (abs (nth 1 scores)) 1e-6))
                   (should (< (nth 2 scores) 0.0))))))))))))

(ert-deftest semantic-finder-ensure-index-embeds-only-missing ()
  "Stale-OK query path: an existing entry is reused even when outdated;
REFRESH re-embeds it."
  (semantic-finder-test--with-table
   (semantic-finder-test--with-buffer "sf-seen" "old content"
     (let ((requested nil)
           (model semantic-finder-base-model))
       (semantic-finder--put buf model -1 [5.0 5.0]) ; stale tick
       (cl-letf (((symbol-function 'semantic-finder-embed)
                  (lambda (texts &optional _model)
                    (setq requested (append requested texts))
                    (mapcar (lambda (_) [1.0 0.0]) texts)))
                 ((symbol-function 'semantic-finder--eligible-p)
                  (lambda (b) (eq b buf))))
         (semantic-finder--ensure-index nil)
         (should (null requested))
         (should (equal [5.0 5.0] (cdr (semantic-finder--entry buf model))))
         (semantic-finder--ensure-index t)
         (should (= 1 (length requested)))
         (should (equal [1.0 0.0] (cdr (semantic-finder--entry buf model))))
         (should (= (buffer-chars-modified-tick buf)
                    (car (semantic-finder--entry buf model)))))))))

;;; Candidate naming

(ert-deftest semantic-finder-window-candidates-score-and-name ()
  (semantic-finder-test--with-buffer "sf-window" "window content"
    (let ((scores (make-hash-table :test #'eq)))
      (set-window-buffer (selected-window) buf)
      (puthash buf 0.75 scores)
      (let ((candidates (semantic-finder--window-candidates scores)))
        (should (= 1 (length candidates)))
        (should (equal (format "%s › %s"
                               (frame-parameter (selected-frame) 'name)
                               (buffer-name buf))
                       (caar candidates)))
        (should (eq (selected-window) (cadr (car candidates))))
        (should (= 0.75 (cddr (car candidates))))))))

(ert-deftest semantic-finder-frame-candidates-take-best-window ()
  (semantic-finder-test--with-buffer "sf-frame" "frame content"
    (let ((scores (make-hash-table :test #'eq)))
      (set-window-buffer (selected-window) buf)
      (puthash buf 0.6 scores)
      (let ((candidates (semantic-finder--frame-candidates scores)))
        (should (= 1 (length candidates)))
        (should (eq (selected-frame) (cadr (car candidates))))
        (should (= 0.6 (cddr (car candidates))))))))

(ert-deftest semantic-finder-by-score-sorts-descending ()
  (should (equal '(("b" x . 0.9) ("a" y . 0.4))
                 (semantic-finder--by-score
                  (list '("a" y . 0.4) '("b" x . 0.9))))))

(provide 'semantic-finder-ert)
;;; semantic-finder-ert.el ends here
