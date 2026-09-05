;;; semantic-finder --- Find buffers, windows, and frames by description -*- lexical-binding: t -*-
;; SPDX-License-Identifier: MIT
;;; Commentary:
;;
;; Retrieval by *description*: "the terminal where the build kept dying
;; on a hash mismatch" shares no substring with the scrollback that
;; matters, so `consult-line-multi' cannot find it.  These commands rank
;; live buffers by embedding similarity against a typed description,
;; using a local tinygrad embedding server (see ch-local-llms'
;; embedding-server home-manager module; buffer contents never leave
;; the machine).
;;
;; A buffer is embedded as its clipped contents behind a contextualizing
;; prefix.  When that exceeds what a model accepts (`/v1/models' reports
;; each model's token cap), it is split into chunks that each repeat
;; the buffer's opening as scoping context, every chunk gets its own
;; vector, and the buffer scores as its best chunk; averaging chunk
;; vectors would dilute the one passage a description is about.
;;
;; The index is an ephemeral in-memory memo table keyed by
;; `buffer-chars-modified-tick', one entry per model.  Two models are
;; involved: a base model the server serves everywhere (small, always
;; available; its vectors survive the server changing device) and an
;; upgrade model it serves only while its GPU is up.  The background
;; indexer keeps the base index fresh and adds the upgrade index
;; whenever the server lists that model; a query uses the upgrade
;; index when the model is available and the base index otherwise, so
;; the server's GPU coming or going never forces a re-index.
;; `semantic-finder-index-mode' warms the table in the background (long
;; scan period with a jittered start, one embed per idle interval); the
;; finder commands work either way, embedding never-seen buffers on
;; demand in one batched request.  Freshness is deliberately stale-OK:
;; a stale entry still describes what was happening in that buffer.  A
;; prefix argument re-embeds every stale buffer before ranking, for the
;; "it just happened" case.
;;
;; The embedding client is also a small API for other packages that
;; rank their own corpora by description (`semantic-finder-embed',
;; `semantic-finder-clip', `semantic-finder-rank'); claude-queue's
;; agent finder ranks session transcripts through it.
;;
;;; Code:

(require 'cl-lib)
(require 'json)
(require 'seq)
(require 'subr-x)
(require 'url)

(defgroup semantic-finder nil
  "Find buffers, windows, and frames by content description."
  :group 'convenience)

(defcustom semantic-finder-endpoint "http://127.0.0.1:9736"
  "Base URL of the local embedding server.
The default matches ch-local-llms' embedding-server home-manager
module, which socket-activates the server on this loopback port."
  :type 'string
  :group 'semantic-finder)

(defcustom semantic-finder-base-model "qwen3-embedding-0.6b"
  "Model whose index is always maintained.
The server serves it on whatever device it has, so vectors of this
model stay valid across the server's device changes.  Nil sends no
model name (the server's default)."
  :type '(choice (const nil) string)
  :group 'semantic-finder)

(defcustom semantic-finder-upgrade-model "qwen3-embedding-4b"
  "Model preferred for ranking whenever the server lists it.
Served only while the server's GPU is up; its index is maintained in
addition to the base index while it is available, and a query falls
back to the base index when it is not.  Nil disables the upgrade."
  :type '(choice (const nil) string)
  :group 'semantic-finder)

(defcustom semantic-finder-models-ttl 60
  "Seconds a `/v1/models' answer is trusted before it is asked again."
  :type 'natnum
  :group 'semantic-finder)

(defcustom semantic-finder-document-prefix
  "An emacs buffer named %s, with the contents:\n"
  "Format string prefixing each embedded buffer; %s is the buffer name.
Contextualizes the document side of the asymmetric query/document
pair: the model should judge \"is this the buffer being described\",
not raw text similarity."
  :type 'string
  :group 'semantic-finder)

(defcustom semantic-finder-query-prefix
  "An emacs buffer matching the description: "
  "Prefix for the typed description before it is embedded.
The query-side counterpart of `semantic-finder-document-prefix'."
  :type 'string
  :group 'semantic-finder)

(defcustom semantic-finder-max-chars 12000
  "Largest content slice embedded per buffer.
About 3000 tokens of code or prose with Qwen3's tokenizer; a model
whose cap is smaller sees the slice in chunks (`semantic-finder-chunk')."
  :type 'natnum
  :group 'semantic-finder)

(defcustom semantic-finder-chars-per-token 3.5
  "Characters per token assumed when sizing chunks for a model's cap.
Qwen3's tokenizer measured 3.7 to 4.2 on code, Nix, Emacs Lisp and
prose; the lower figure leaves headroom for denser text."
  :type 'number
  :group 'semantic-finder)

(defcustom semantic-finder-chunk-reserve-chars 200
  "Characters of a model's budget held back for the document prefix
and the ellipsis marker."
  :type 'natnum
  :group 'semantic-finder)

(defcustom semantic-finder-chunk-head-chars 1500
  "Characters from the start of a buffer repeated in every chunk.
A buffer's opening usually scopes the rest (a chat's first question,
a module's docstring and imports), so a chunk embedded without it is a
fragment of unknown subject.  Capped at a third of the chunk budget."
  :type 'natnum
  :group 'semantic-finder)

(defcustom semantic-finder-index-period 300
  "Seconds between background scans for stale buffers."
  :type 'natnum
  :group 'semantic-finder)

(defcustom semantic-finder-index-jitter 60
  "Upper bound on the random offset added to the first scan.
Keeps a fleet of simultaneously started sessions from herding."
  :type 'natnum
  :group 'semantic-finder)

(defcustom semantic-finder-drip-idle 3
  "Idle seconds before the indexer embeds one queued buffer."
  :type 'natnum
  :group 'semantic-finder)

(defcustom semantic-finder-request-timeout 60
  "Seconds to wait for a synchronous embedding request.
Covers the socket-activated server's cold start (model load)."
  :type 'natnum
  :group 'semantic-finder)

(defcustom semantic-finder-backoff 900
  "Seconds to pause background indexing after a failed request.
Keeps sessions on machines without the embedding server quiet."
  :type 'natnum
  :group 'semantic-finder)

(defvar semantic-finder--table (make-hash-table :test #'eq)
  "Memo table: buffer -> alist of (MODEL . (TICK . EMBEDDING)).
The single source of truth; the background indexer only warms it.
MODEL is the model name the vector was requested with (nil for the
server's default).  EMBEDDING is one vector, or a list of vectors when
the buffer was embedded in chunks (`semantic-finder--pack').")

(defvar semantic-finder--queue nil
  "(BUFFER . MODEL) pairs the last scan found stale, awaiting a drip embed.")

(defvar semantic-finder--models nil
  "(TIME . MODELS): the server's `/v1/models' answer, cached.
MODELS is a list of (ID . MAX-TOKENS); MAX-TOKENS is nil when the
server did not say.  A nil MODELS under a TIME records a failed or
empty answer, so the server is left alone until the cache expires.")

(defvar semantic-finder--models-refresh nil
  "Token for the outstanding asynchronous `/v1/models' refresh, or nil.
A fresh (TIME) list per request; the callback clears only its own
token, and a token older than `semantic-finder-request-timeout'
counts as lost, freeing the next caller to ask again.")

(defvar semantic-finder--scan-timer nil)
(defvar semantic-finder--drip-timer nil)

(defvar semantic-finder--inflight nil
  "Token for the outstanding asynchronous embed request, or nil.
A fresh (TIME) list per request; the callback clears only its own
token, and a token older than `semantic-finder-request-timeout'
counts as lost, which `semantic-finder--drip' treats as a failure:
a server that accepts connections and never answers must not wedge
indexing forever.")

(defvar semantic-finder--backoff-until nil
  "Time before which background indexing stays paused.")

(defvar semantic-finder--history nil
  "Minibuffer history for description queries.")

;;; Index bookkeeping

(defun semantic-finder--eligible-p (buffer)
  "Whether BUFFER participates in description ranking."
  (and (buffer-live-p buffer)
       (not (string-prefix-p " " (buffer-name buffer)))
       (not (minibufferp buffer))
       (> (buffer-size buffer) 0)))

(defun semantic-finder--entry (buffer model)
  "The (TICK . EMBEDDING) memoized for BUFFER under MODEL, or nil."
  (cdr (assoc model (gethash buffer semantic-finder--table))))

(defun semantic-finder--put (buffer model tick embedding)
  "Memoize EMBEDDING of BUFFER at TICK under MODEL."
  (let ((rest (assoc-delete-all model (gethash buffer semantic-finder--table))))
    (puthash buffer (cons (cons model (cons tick embedding)) rest)
             semantic-finder--table)))

(defun semantic-finder--stale-p (buffer &optional model)
  "Whether BUFFER's entry under MODEL is missing or outdated.
MODEL defaults to the base model."
  (let ((entry (semantic-finder--entry
                buffer (or model semantic-finder-base-model))))
    (or (null entry)
        (/= (car entry) (buffer-chars-modified-tick buffer)))))

(defun semantic-finder-clip (text)
  "TEXT clipped to `semantic-finder-max-chars'.
Oversize text contributes its head third and tail two-thirds — the
tail is where recent activity lives, the head is where a document
declares what it is."
  (let ((max semantic-finder-max-chars))
    (if (<= (length text) max)
        text
      (let ((head (/ max 3)))
        (concat (substring text 0 head)
                "\n[…]\n"
                (substring text (- (length text) (- max head))))))))

(defun semantic-finder-chunk (text budget)
  "TEXT as a list of pieces of at most BUDGET characters.
TEXT whole when it fits or BUDGET is nil.  Otherwise every piece
starts with TEXT's first `semantic-finder-chunk-head-chars' (at most a
third of BUDGET) as scoping context; the first piece continues
straight into the text, later ones mark the gap with an ellipsis, and
the windows after the head cover the rest of TEXT without overlap."
  (if (or (null budget) (<= (length text) budget))
      (list text)
    (let* ((head-len (min semantic-finder-chunk-head-chars (/ budget 3)))
           (head (substring text 0 head-len))
           (marker "\n[…]\n")
           (window (max 1 (- budget head-len (length marker))))
           (pos head-len)
           chunks)
      (while (< pos (length text))
        (let ((end (min (length text) (+ pos window))))
          (push (concat head (if (= pos head-len) "" marker)
                        (substring text pos end))
                chunks)
          (setq pos end)))
      (nreverse chunks))))

(defun semantic-finder--chunk-budget (model)
  "Characters of buffer text one request to MODEL may carry, or nil.
Nil when the server does not report a cap for MODEL: the text goes
whole and the server truncates."
  (when-let* ((max-tokens (semantic-finder--model-max-tokens model)))
    (max 1 (- (floor (* max-tokens semantic-finder-chars-per-token))
              semantic-finder-chunk-reserve-chars))))

(defun semantic-finder--buffer-slice (buffer)
  "BUFFER's contents clipped by `semantic-finder-clip'."
  (with-current-buffer buffer
    (save-restriction
      (widen)
      (semantic-finder-clip
       (buffer-substring-no-properties (point-min) (point-max))))))

(defun semantic-finder--buffer-text (buffer)
  "Text embedded for BUFFER: a contextualizing prefix, its name, and
its contents clipped by `semantic-finder-clip'.  The unchunked form."
  (concat (format semantic-finder-document-prefix (buffer-name buffer))
          (semantic-finder--buffer-slice buffer)))

(defun semantic-finder--buffer-texts (buffer model)
  "Texts embedded for BUFFER under MODEL, one per chunk.
Each is the document prefix with the buffer's name and one piece of
`semantic-finder-chunk' over the clipped contents, sized to MODEL's
cap; one text when the slice fits."
  (let ((prefix (format semantic-finder-document-prefix (buffer-name buffer))))
    (mapcar (lambda (chunk) (concat prefix chunk))
            (semantic-finder-chunk (semantic-finder--buffer-slice buffer)
                                   (semantic-finder--chunk-budget model)))))

(defun semantic-finder--pack (vectors)
  "The memoized form of VECTORS: the vector itself for one, the list
for several."
  (if (cdr vectors) vectors (car vectors)))

;;; Embedding requests

(defun semantic-finder--scrub (text)
  "TEXT with raw bytes replaced by the Unicode replacement character.
Process-fed buffers (terminals, jsonrpc event logs) can hold bytes
that never decoded to characters; `json-serialize' rejects any
string containing one."
  (replace-regexp-in-string
   "[\x3fff80-\x3fffff]" "�"
   (if (multibyte-string-p text) text (decode-coding-string text 'utf-8))))

(defun semantic-finder--payload (texts &optional model)
  "JSON request body embedding TEXTS with MODEL (when non-nil), as unibyte."
  (encode-coding-string
   (json-serialize
    (append (list :input (vconcat (mapcar #'semantic-finder--scrub texts)))
            (and model (list :model model))))
   'utf-8))

(defun semantic-finder--url ()
  (concat semantic-finder-endpoint "/v1/embeddings"))

(defun semantic-finder--parse-models-response ()
  "Parse a /v1/models response in the current url buffer.
A list of (ID . MAX-TOKENS), MAX-TOKENS nil when absent; nil on any
failure."
  (goto-char (point-min))
  (when (re-search-forward "^$" nil t)
    (let* ((json (ignore-errors (json-parse-buffer :object-type 'alist)))
           (data (alist-get 'data json)))
      (when (vectorp data)
        (mapcar (lambda (item)
                  (cons (alist-get 'id item)
                        (let ((cap (alist-get 'max_tokens item)))
                          (and (integerp cap) cap))))
                (append data nil))))))

(defun semantic-finder--models-fresh-p ()
  (and semantic-finder--models
       (< (float-time (time-since (car semantic-finder--models)))
          semantic-finder-models-ttl)))

(defun semantic-finder--token-outstanding-p (token)
  "Whether TOKEN, a (TIME) request token, is still worth waiting on."
  (and token
       (< (float-time (time-since (car token)))
          semantic-finder-request-timeout)))

(defun semantic-finder--refresh-models ()
  "Kick an asynchronous `/v1/models' refresh when the cache is stale.
Never blocks and never signals: callers read `semantic-finder--models'
as it stands and pick the answer up on a later call.  A failed request
caches an empty answer, so the server is asked again only after
`semantic-finder-models-ttl' seconds; a request that never comes back
frees the slot after `semantic-finder-request-timeout'."
  (unless (or (semantic-finder--models-fresh-p)
              (semantic-finder--token-outstanding-p
               semantic-finder--models-refresh))
    (let ((token (list (current-time))))
      (setq semantic-finder--models-refresh token)
      (condition-case nil
          (url-retrieve
           (concat semantic-finder-endpoint "/v1/models")
           (lambda (_status)
             (unwind-protect
                 (setq semantic-finder--models
                       (cons (current-time)
                             (semantic-finder--parse-models-response)))
               (when (eq semantic-finder--models-refresh token)
                 (setq semantic-finder--models-refresh nil))
               (kill-buffer (current-buffer))))
           nil t t)
        (error
         (setq semantic-finder--models (cons (current-time) nil))
         (when (eq semantic-finder--models-refresh token)
           (setq semantic-finder--models-refresh nil)))))))

(defun semantic-finder--model-entries ()
  "The server's models as (ID . MAX-TOKENS) pairs, from the cache.
The cached answer comes back as it stands (possibly stale, nil before
the first answer has arrived), and a stale cache schedules an
asynchronous refresh; nothing here waits on the network, so the
finder can never freeze the editor however sick the server is.  A
bare id in the answer (an older server, a test) counts as an id with
no cap."
  (semantic-finder--refresh-models)
  (mapcar (lambda (entry) (if (consp entry) entry (cons entry nil)))
          (cdr semantic-finder--models)))

(defun semantic-finder--models-known-p ()
  "Whether the server has listed at least one model, as far as the
cache can say."
  (consp (cdr semantic-finder--models)))

(defun semantic-finder--available-models ()
  "Model ids the server serves right now."
  (mapcar #'car (semantic-finder--model-entries)))

(defun semantic-finder--model-max-tokens (model)
  "The token cap the server reports for MODEL, or nil."
  (cdr (assoc model (semantic-finder--model-entries))))

(defun semantic-finder--upgrade-available-p ()
  "Whether the upgrade model is configured and the server lists it."
  (and semantic-finder-upgrade-model
       (member semantic-finder-upgrade-model
               (semantic-finder--available-models))
       t))

(defun semantic-finder--query-model ()
  "The model a query should rank with right now."
  (if (semantic-finder--upgrade-available-p)
      semantic-finder-upgrade-model
    semantic-finder-base-model))

(defun semantic-finder--parse-response ()
  "Parse a /v1/embeddings response in the current url buffer.
Return the embeddings as a list in input order, nil on any failure."
  (goto-char (point-min))
  (when (re-search-forward "^$" nil t)
    (let* ((json (ignore-errors (json-parse-buffer :object-type 'alist)))
           (data (alist-get 'data json)))
      (when (vectorp data)
        (mapcar (lambda (item) (alist-get 'embedding item))
                (sort (append data nil)
                      (lambda (a b)
                        (< (alist-get 'index a) (alist-get 'index b)))))))))

(defun semantic-finder-embed (texts &optional model)
  "Embed TEXTS (a list of strings) with MODEL synchronously; list of vectors.
MODEL defaults to the base model; nil there sends no model name.
Signals `user-error' when the server is unreachable or errors."
  (let ((url-request-method "POST")
        (url-request-extra-headers '(("Content-Type" . "application/json")))
        (url-request-data (semantic-finder--payload
                           texts (or model semantic-finder-base-model)))
        buffer)
    (condition-case err
        (setq buffer (url-retrieve-synchronously
                      (semantic-finder--url) t nil
                      semantic-finder-request-timeout))
      (error
       (user-error "Embedding server unreachable at %s (%s)"
                   semantic-finder-endpoint (error-message-string err))))
    (unless buffer
      (user-error "Embedding server unreachable at %s" semantic-finder-endpoint))
    (unwind-protect
        (with-current-buffer buffer
          (or (semantic-finder--parse-response)
              (user-error "Embedding request failed: %s"
                          (string-limit (buffer-string) 200))))
      (kill-buffer buffer))))

(defun semantic-finder--back-off ()
  "Pause background indexing after a failed request."
  (setq semantic-finder--queue nil
        semantic-finder--backoff-until (time-add nil semantic-finder-backoff)))

(defun semantic-finder--backing-off-p ()
  (and semantic-finder--backoff-until
       (time-less-p nil semantic-finder--backoff-until)))

(defun semantic-finder--embed-async (buffer model)
  "Embed BUFFER with MODEL in the background and memoize the result.
Errors back the indexer off instead of escaping to the timer, where
they would be messaged — with the buffer text — on every drip."
  (condition-case nil
      (let ((tick (buffer-chars-modified-tick buffer))
            (token (list (current-time)))
            (url-request-method "POST")
            (url-request-extra-headers '(("Content-Type" . "application/json")))
            (url-request-data
             (semantic-finder--payload
              (semantic-finder--buffer-texts buffer model) model)))
        (setq semantic-finder--inflight token)
        (url-retrieve
         (semantic-finder--url)
         (lambda (_status)
           (unwind-protect
               (let ((embeddings (semantic-finder--parse-response)))
                 (if (null embeddings)
                     (semantic-finder--back-off)
                   (when (buffer-live-p buffer)
                     (semantic-finder--put buffer model tick
                                           (semantic-finder--pack embeddings)))))
             (when (eq semantic-finder--inflight token)
               (setq semantic-finder--inflight nil))
             (kill-buffer (current-buffer)))
           (semantic-finder--drip-continue))
         nil t t))
    (error
     (setq semantic-finder--inflight nil)
     (semantic-finder--back-off))))

;;; Background indexer

(defun semantic-finder--index-models ()
  "Models the background indexer maintains right now: the base model
always, the upgrade model while the server lists it."
  (if (semantic-finder--upgrade-available-p)
      (list semantic-finder-base-model semantic-finder-upgrade-model)
    (list semantic-finder-base-model)))

(defun semantic-finder--scan ()
  "Prune dead buffers and queue stale (BUFFER . MODEL) pairs for the drip.
The base model's stale buffers come first, so the always-available
index is the one kept freshest."
  (maphash (lambda (buffer _)
             (unless (buffer-live-p buffer)
               (remhash buffer semantic-finder--table)))
           semantic-finder--table)
  (unless (semantic-finder--backing-off-p)
    (let ((buffers (seq-filter #'semantic-finder--eligible-p (buffer-list))))
      (setq semantic-finder--queue
            (cl-loop for model in (semantic-finder--index-models)
                     append (cl-loop for buffer in buffers
                                     when (semantic-finder--stale-p buffer model)
                                     collect (cons buffer model)))))))

(defun semantic-finder--drip ()
  "Embed the next queued buffer, one request at a time.
An embed request that never came back counts as failed once it is
older than `semantic-finder-request-timeout' and backs the indexer
off.  Embedding also waits until the server has actually listed its
models: the answer sizes the chunks, and while it is missing the
drip only keeps the asynchronous refresh moving."
  (when (and semantic-finder--inflight
             (not (semantic-finder--token-outstanding-p
                   semantic-finder--inflight)))
    (setq semantic-finder--inflight nil)
    (semantic-finder--back-off))
  (unless (or semantic-finder--inflight (semantic-finder--backing-off-p))
    (semantic-finder--refresh-models)
    (when (semantic-finder--models-known-p)
      (let (task)
        (while (and semantic-finder--queue (null task))
          (let ((next (pop semantic-finder--queue)))
            (when (and (semantic-finder--eligible-p (car next))
                       (semantic-finder--stale-p (car next) (cdr next)))
              (setq task next))))
        (when task
          (semantic-finder--embed-async (car task) (cdr task)))))))

(defun semantic-finder--drip-continue ()
  "Keep dripping through a single long idle stretch.
A repeating idle timer fires only once per stretch, so the async
completion re-arms a short one-shot while the user stays idle."
  (when (and semantic-finder--queue
             (current-idle-time)
             (time-less-p semantic-finder-drip-idle (current-idle-time)))
    (run-with-timer 0.5 nil #'semantic-finder--drip)))

;;;###autoload
(define-minor-mode semantic-finder-index-mode
  "Keep a background embedding index of buffer contents warm.
The finder commands work without it — never-indexed buffers are
embedded on demand — but with it, ranking needs no synchronous sweep."
  :global t
  (if semantic-finder-index-mode
      (setq semantic-finder--scan-timer
            (run-with-timer (+ semantic-finder-index-period
                               (random (max 1 semantic-finder-index-jitter)))
                            semantic-finder-index-period
                            #'semantic-finder--scan)
            semantic-finder--drip-timer
            (run-with-idle-timer semantic-finder-drip-idle t
                                 #'semantic-finder--drip))
    (when semantic-finder--scan-timer
      (cancel-timer semantic-finder--scan-timer))
    (when semantic-finder--drip-timer
      (cancel-timer semantic-finder--drip-timer))
    (setq semantic-finder--scan-timer nil
          semantic-finder--drip-timer nil
          semantic-finder--queue nil)))

;;; Ranking

(defun semantic-finder--cosine (a b)
  "Cosine similarity of vectors A and B."
  (let ((dot 0.0) (na 0.0) (nb 0.0))
    (dotimes (i (length a))
      (let ((x (float (aref a i)))
            (y (float (aref b i))))
        (setq dot (+ dot (* x y))
              na (+ na (* x x))
              nb (+ nb (* y y)))))
    (if (or (zerop na) (zerop nb))
        0.0
      (/ dot (sqrt (* na nb))))))

(defun semantic-finder--ensure-index (refresh &optional model)
  "Batch-embed buffers the table cannot rank under MODEL.
Return the eligible buffers.  MODEL defaults to the base model.
Without REFRESH only never-indexed
buffers are embedded (stale entries still rank on their old vector);
with it, every stale buffer is."
  (let* ((model (or model semantic-finder-base-model))
         (buffers (seq-filter #'semantic-finder--eligible-p (buffer-list)))
         (missing (seq-filter
                   (lambda (buffer)
                     (if refresh
                         (semantic-finder--stale-p buffer model)
                       (null (semantic-finder--entry buffer model))))
                   buffers)))
    (when missing
      ;; One request carries every chunk of every missing buffer; the
      ;; answer is regrouped by each buffer's chunk count.
      (let* ((ticks (mapcar #'buffer-chars-modified-tick missing))
             (texts (mapcar (lambda (buffer)
                              (semantic-finder--buffer-texts buffer model))
                            missing))
             (embeddings (semantic-finder-embed (apply #'append texts) model)))
        (cl-mapc (lambda (buffer tick chunk-texts)
                   (let ((n (length chunk-texts)))
                     (semantic-finder--put
                      buffer model tick
                      (semantic-finder--pack (seq-take embeddings n)))
                     (setq embeddings (nthcdr n embeddings))))
                 missing ticks texts)))
    buffers))

(defun semantic-finder--subtract (vector base)
  "VECTOR minus BASE, elementwise."
  (let ((out (make-vector (length vector) 0.0)))
    (dotimes (i (length vector))
      (aset out i (- (float (aref vector i)) (aref base i))))
    out))

(defvar semantic-finder--anchor-cache (make-hash-table :test #'equal)
  "(ENDPOINT MODEL DOC-TEXT QUERY-TEXT) -> (DOC-ANCHOR . QUERY-ANCHOR).")

(defun semantic-finder--anchors (doc-text query-text &optional model)
  "Embedded boilerplate anchors as (DOC-ANCHOR . QUERY-ANCHOR).
Cached per MODEL (default the base model).
DOC-TEXT and QUERY-TEXT are the two sides' bare contextualizing
prefixes; for the buffer finders the document side is the document
prefix with an empty name, so the shared boilerplate cancels while
the buffer name keeps some weight."
  (let* ((model (or model semantic-finder-base-model))
         (key (list semantic-finder-endpoint model doc-text query-text)))
    (or (gethash key semantic-finder--anchor-cache)
        (puthash key
                 (let ((vectors (semantic-finder-embed
                                 (list doc-text query-text) model)))
                   (cons (nth 0 vectors) (nth 1 vectors)))
                 semantic-finder--anchor-cache))))

(defun semantic-finder--score (query embedding doc-anchor)
  "Cosine of QUERY against EMBEDDING's residual from DOC-ANCHOR.
EMBEDDING is one vector or a list of chunk vectors; a document scores
as its best chunk, so the one passage a description is about is not
diluted by the rest."
  (if (listp embedding)
      (apply #'max (mapcar (lambda (chunk)
                             (semantic-finder--score query chunk doc-anchor))
                           embedding))
    (semantic-finder--cosine
     query (semantic-finder--subtract embedding doc-anchor))))

(defun semantic-finder-rank (description entries doc-anchor-text query-prefix
                                         &optional model)
  "Rank ENTRIES against DESCRIPTION: ((KEY . SCORE) …), best first.
ENTRIES are (KEY . EMBEDDING) pairs over documents already embedded
with `semantic-finder-embed' under MODEL (default the base model);
EMBEDDING is one vector, or a list of them for a document embedded in
chunks, which scores as its best chunk.  DOC-ANCHOR-TEXT is the
boilerplate the documents share (their contextualizing prefix minus
any per-document part), QUERY-PREFIX the one prepended to DESCRIPTION.

Scores are cosine similarities between boilerplate-subtracted
residuals: each side first sheds an embedded anchor of its own bare
prefix (`semantic-finder--anchors').  Raw CLS cosines share a large
common component fed by the contextualizing boilerplate, so thin
documents that are mostly prefix hub near every query.  Corpus
mean-centering (the first attempt) only relocates the problem: a
short query is itself mostly boilerplate, and its residual from the
code-heavy document mean points straight at the odd document out.
Anchors cancel each side's boilerplate exactly and are
corpus-independent, so a document's score against a description does
not shift as other documents come and go."
  (let* ((model (or model semantic-finder-base-model))
         (anchors (semantic-finder--anchors doc-anchor-text query-prefix model))
         (query (semantic-finder--subtract
                 (car (semantic-finder-embed
                       (list (concat query-prefix description)) model))
                 (cdr anchors))))
    (sort (mapcar (lambda (entry)
                    (cons (car entry)
                          (semantic-finder--score query (cdr entry)
                                                  (car anchors))))
                  entries)
          (lambda (a b) (> (cdr a) (cdr b))))))

(defun semantic-finder--ranked (description refresh)
  "Rank live buffers against DESCRIPTION: ((BUFFER . SCORE) …), best first.
Uses the upgrade model when the server lists it and the base model
otherwise (`semantic-finder--query-model'); REFRESH is passed to
`semantic-finder--ensure-index'; scoring is `semantic-finder-rank'
over the memo table's embeddings under that model."
  (let ((model (semantic-finder--query-model)))
    (semantic-finder-rank
     description
     (delq nil
           (mapcar (lambda (buffer)
                     (when-let* ((entry (semantic-finder--entry buffer model)))
                       (cons buffer (cdr entry))))
                   (semantic-finder--ensure-index refresh model)))
     (format semantic-finder-document-prefix "")
     semantic-finder-query-prefix
     model)))

(defun semantic-finder--scores (description refresh)
  "Hash table BUFFER -> SCORE against DESCRIPTION."
  (let ((scores (make-hash-table :test #'eq)))
    (dolist (pair (semantic-finder--ranked description refresh) scores)
      (puthash (car pair) (cdr pair) scores))))

;;; Selection UI

(defun semantic-finder--read (prompt candidates category)
  "Choose from CANDIDATES — ((NAME PAYLOAD . SCORE) …) in rank order.
Identity sorters keep that order; the score annotates each line.
Return the chosen PAYLOAD."
  (unless candidates
    (user-error "Nothing to rank against that description"))
  (let* ((table (lambda (string pred action)
                  (if (eq action 'metadata)
                      `(metadata (category . ,category)
                                 (display-sort-function . identity)
                                 (cycle-sort-function . identity)
                                 (annotation-function
                                  . ,(lambda (name)
                                       (format "  %.2f"
                                               (cddr (assoc name candidates))))))
                    (complete-with-action action candidates string pred))))
         (choice (completing-read prompt table nil t nil nil
                                  (caar candidates))))
    (cadr (assoc choice candidates))))

(defun semantic-finder--read-query ()
  (list (read-string "Description: " nil 'semantic-finder--history)
        current-prefix-arg))

(defun semantic-finder--window-candidates (scores)
  "Window candidates over all frames, named as `find-window-anywhere' does."
  (let ((seen (make-hash-table :test #'equal)))
    (delq nil
          (mapcar
           (lambda (window)
             (when-let* ((score (gethash (window-buffer window) scores)))
               (let* ((base (format "%s › %s"
                                    (frame-parameter (window-frame window) 'name)
                                    (buffer-name (window-buffer window))))
                      (n (gethash base seen 0))
                      (name (if (zerop n) base (format "%s <%d>" base n))))
                 (puthash base (1+ n) seen)
                 (cons name (cons window score)))))
           (window-list-1 nil 0 t)))))

(defun semantic-finder--frame-candidates (scores)
  "Frame candidates; a frame scores as its best-matching window."
  (let ((seen (make-hash-table :test #'equal)))
    (delq nil
          (mapcar
           (lambda (frame)
             (let (best)
               (dolist (window (window-list frame 0))
                 (when-let* ((score (gethash (window-buffer window) scores)))
                   (when (or (null best) (> score best))
                     (setq best score))))
               (when best
                 (let* ((base (frame-parameter frame 'name))
                        (n (gethash base seen 0))
                        (name (if (zerop n) base (format "%s <%d>" base n))))
                   (puthash base (1+ n) seen)
                   (cons name (cons frame best))))))
           (frame-list)))))

(defun semantic-finder--by-score (candidates)
  (sort candidates (lambda (a b) (> (cddr a) (cddr b)))))

;;; Commands

;;;###autoload
(defun find-buffer-by-description (description &optional refresh)
  "Switch to the buffer whose content best matches DESCRIPTION.
Ranking uses whatever the index holds (stale is fine — it still says
what was happening there); never-indexed buffers are embedded first in
one batch.  With a prefix argument REFRESH, re-embed every stale
buffer before ranking."
  (interactive (semantic-finder--read-query))
  (let ((candidates
         (mapcar (lambda (pair)
                   (cons (buffer-name (car pair)) pair))
                 (semantic-finder--ranked description refresh))))
    (switch-to-buffer
     (semantic-finder--read "Buffer: " candidates 'buffer))))

;;;###autoload
(defun find-window-by-description (description &optional refresh)
  "Select the window (on any frame) best matching DESCRIPTION.
Also gives that window's frame input focus.  REFRESH as in
`find-buffer-by-description'."
  (interactive (semantic-finder--read-query))
  (let* ((scores (semantic-finder--scores description refresh))
         (window (semantic-finder--read
                  "Window: "
                  (semantic-finder--by-score
                   (semantic-finder--window-candidates scores))
                  'window)))
    (unless (window-live-p window)
      (user-error "Window no longer live"))
    (select-frame-set-input-focus (window-frame window))
    (select-window window)))

;;;###autoload
(defun find-frame-by-description (description &optional refresh)
  "Focus the frame showing content that best matches DESCRIPTION.
A frame ranks by its best-matching window.  REFRESH as in
`find-buffer-by-description'."
  (interactive (semantic-finder--read-query))
  (let* ((scores (semantic-finder--scores description refresh))
         (frame (semantic-finder--read
                 "Frame: "
                 (semantic-finder--by-score
                  (semantic-finder--frame-candidates scores))
                 'frame)))
    (unless (frame-live-p frame)
      (user-error "Frame no longer live"))
    (select-frame-set-input-focus frame)))

(provide 'semantic-finder)
;;; semantic-finder.el ends here
