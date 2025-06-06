;;; dix.el --- Apertium XML editing minor mode -*- lexical-binding: t -*-

;; Copyright (C) 2009-2023 Kevin Brubeck Unhammer

;; Author: Kevin Brubeck Unhammer <unhammer@fsfe.org>
;; Version: 0.4.1
;; Url: http://wiki.apertium.org/wiki/Emacs
;; Keywords: languages
;; Package-Requires: ((cl-lib "0.5") (emacs "26.2"))

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 2, or (at your option)
;; any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; Basic usage:
;;
;; (add-hook 'nxml-mode-hook #'dix-on-nxml-mode)
;;
;; Unless you installed from MELPA, you'll also need
;;
;; (add-to-list 'load-path "/path/to/dix.el-folder")
;; (autoload 'dix-mode "dix"
;;   "dix-mode is a minor mode for editing Apertium XML dictionary files."  t)
;;
;; If you actually work on Apertium packages, you'll probaby want some
;; other related Emacs extensions as well; see
;; http://wiki.apertium.org/wiki/Emacs#Quickstart for an init file
;; that installs and configures both dix.el and some related packages.

;; Optional dependencies:
;; * `strie' – for the `dix-guess-pardef' function

;; If you want keybindings that use `C-c' followed by letters, you
;; should also add
;; (add-hook 'dix-mode-hook #'dix-C-c-letter-keybindings)
;; These are not turned on by default, since `C-c' followed by letters
;; is meant to be reserved for user preferences.

;; Useful functions (some using C-c-letter-keybindings): `C-c <left>'
;; creates an LR-restricted copy of the <e>-element at point, `C-c
;; <right>' an RL-restricted one.  `C-TAB' cycles through the
;; restriction possibilities (LR, RL, none), while `M-n' and `M-p'
;; move to the next and previous "important bits" of <e>-elements
;; (just try it!).  `C-c S' sorts a pardef, while `M-.'  moves point
;; to the pardef of the entry at point, leaving mark where you left
;; from (`M-.' will go back).  `C-c \' greps the pardef/word at point
;; using the dictionary files represented by the string
;; `dix-dixfiles', while `C-c D' gives you a list of all pardefs which
;; use these suffixes (where a suffix is the contents of an
;; <l>-element).

;; `M-x dix-suffix-sort' is a general function, useful outside of dix
;; XML files too, that just reverses each line, sorts them, and
;; reverses them back.  `C-c % %' is a convenience function for
;; regexp-replacing text within certain XML elements, eg. all <e>
;; elements; `C-c % r' and `C-c % l' are specifically for <r> and <l>
;; elements, respectively.

;; I like having the following set too:
;; (setq nxml-sexp-element-flag t 		; treat <e>...</e> as a sexp
;;       nxml-completion-hook '(rng-complete t) ; C-RET completes based on DTD
;;       rng-nxml-auto-validate-flag nil)       ; 8MB of XML takes a while
;; You can always turn on validation again with C-c C-v.  Validation
;; is necessary for the C-RET completion, which is really handy in
;; transfer files.

;; I haven't bothered with defining a real indentation function, but
;; if you like having all <i> elements aligned at eg. column 25, the
;; align rules defined here let you do M-x align on a region to
;; achieve that, and also aligns <p> and <r>.  Set your favorite
;; column numbers with M-x customize-group RET dix.

;; Plan / long term TODO:
;; - Yank into <i/l/r> or pardef n="" should replace spaces with either
;;   a <b/> or a _
;; - Functions shouldn't modify the kill-ring.
;; - Functions should be agnostic to formatting (ie. only use nxml
;;   movement functions, never forward-line).
;; - Real indentation function for one-entry-one-line format.
;; - `dix-LR-restriction-copy' should work on a region of <e>'s.
;; - `dix-expand-lemma-at-point' (either using `dix-goto-pardef' or
;;   `lt-expand')
;; - Some sort of interactive view of the translation process . When
;;   looking at a word in monodix, you should easily get confirmation on
;;   whether (and what) it is in the bidix or other monodix (possibly
;;   just using `apertium-transfer' and `lt-proc' on the expanded
;;   paradigm).
;; - Function for creating a prelimenary list of bidix entries from
;;   monodix entries, and preferably from two such lists which
;;   we "paste" side-by-side.
;; - `dix-LR-restriction-copy' (and the other copy functions) could
;;   add a="author"
;; - `dix-dixfiles' could auto-add files from Makefile?
;; - `dix-sort-e-by-r' doesn't work if there's an <re> element after
;;   the <r>; and doesn't sort correctly by <l>-element, possibly to
;;   do with spaces
;; - `dix-reverse' should be able to reverse on a regexp match, so
;;   that we can do `dix-suffix-sort' by eg. <l>-elements.
;; - Investigate if Emacs built-in `tildify-mode' should be used to
;;   implement `dix-space'.

;;; Code:

(defconst dix-version "0.4.1")

(require 'nxml-mode)
(require 'cl-lib)
(require 'easymenu)
(require 'subr-x)
(eval-when-compile (require 'align))

;;;============================================================================
;;;
;;; Define the formal stuff for a minor mode named dix.
;;;

(defvar dix-mode-map (make-sparse-keymap)
  "Keymap for dix minor mode.")

(defvar dix-mode-syntax-table
  (let ((st (copy-syntax-table nxml-mode-syntax-table)))
    (modify-syntax-entry ?< "(" st)
    (modify-syntax-entry ?> ")" st)
    (modify-syntax-entry ?@ "_" st)
    (modify-syntax-entry ?: "_" st)
    (modify-syntax-entry ?. "_" st)
    st)
  "Syntax table for dix minor mode.")

(defgroup dix nil
  "Minor mode for editing Apertium XML dictionaries."
  :tag "Apertium dix"
  :group 'nxml)

;;;###autoload
(define-minor-mode dix-mode
  "Toggle dix-mode.
With arg, turn on dix-mode if and only if arg is positive.

dix-mode is a minor mode for editing Apertium XML dictionary files.

                             KEY BINDINGS
                             ------------
\\{dix-mode-map}

Entering dix-mode calls the hook dix-mode-hook.
------------------------------------------------------------------------------"
  :init-value nil
  :lighter    " dix"
  :keymap     dix-mode-map
  :require    nxml-mode

  (when (member (file-name-extension (or (buffer-file-name) "")) '("dix" "metadix"))
    (font-lock-add-keywords nil
                    '(("<[lr]>\\(?:[^<]\\|<b/>\\)*\\( \\)"
                       . (progn         ; based on rng-mark-error
                           (dix-mark-error "Use <b/> instead of literal space"
                                        (match-beginning 1)
                                        (match-end 1))
                           nil)))))
  (when (dix-is-transfer)
    (font-lock-add-keywords nil
                    '(("<lit-tag v=\"\"/>"
                       . (progn         ; based on rng-mark-error
                           (dix-mark-error "Use lit instead of lit-tag to match empty strings"
                                        (match-beginning 0)
                                        (match-end 0))
                           nil)))))
  (when (dix-is-lrx)
    (font-lock-add-keywords nil
                    '(("<match[^>]*\\(></match>\\)"
                       . (progn         ; based on rng-mark-error
                           (dix-mark-error "Use /> instead of ></match>"
                                        (match-beginning 1)
                                        (match-end 1))
                           nil)))))
  (set-syntax-table dix-mode-syntax-table)
  (dix-imenu-setup))

(defvar dix-file-name-patterns
  "\\.\\(meta\\|multi\\)?dix$\\|\\.t[0-9s]x$\\|\\.l[sr]x$\\|\\.metalrx$\\|/modes\\.xml$\\|/cross-model\\.xml$")

(defun dix-on-nxml-mode ()
  "Turn on dix-mode if suitable dix file extension.
Usage: (add-hook 'nxml-mode-hook #'dix-on-nxml-mode)."
  (when (and (buffer-file-name)
             (string-match dix-file-name-patterns buffer-file-name))
    (modify-syntax-entry ?> ")<" nxml-mode-syntax-table)
    (modify-syntax-entry ?< "(>" nxml-mode-syntax-table)
    (dix-mode 1)))

(defun dix-mark-error (message beg end)
  "Create an error overlay with the dix-error category.
MESSAGE, BEG and END as in `rng-mark-error'."
  (let ((overlay
         (make-overlay beg end nil t
                       (= beg end))))
    (overlay-put overlay 'priority beg)
    (overlay-put overlay 'category 'dix-error)
    (overlay-put overlay 'help-echo message)))

(put 'dix-error 'face 'rng-error)

;;;============================================================================
;;;
;;; Menu
;;;

(easy-menu-define dix-mode-easy-menu dix-mode-map "dix-mode menu"
  '("dix"
    ["View pardef" dix-view-pardef
     :help "View the pardef in another window"]
    ["Go to pardef" dix-goto-pardef]
    ("Guess pardef of the word on this line..."
     :help "Write a single word on a line, place point somewhere inside the word, and this will guess the pardef using the above entries."
     ["with no PoS restriction" dix-guess-pardef
      :help "Write a single word on a line, place point somewhere inside the word, and this will guess the pardef using the above entries."])
    "---"
    ["Sort pardef" dix-sort-pardef
     :help "Must be called from within a pardef"]
    ["Grep for this pardef in dix-dixfiles" dix-grep-all
     :help "Must be called from within a pardef. Uses the variable dix-dixfiles"]
    ["Show Duplicate pardefs" dix-find-duplicate-pardefs
     :help "Must be called from within a pardef. Calculate must have been called at least once"]
    ["Calculate and Show Duplicate pardefs" (dix-find-duplicate-pardefs 'recompile)
     :keys "C-u C-c D"
     :help "Must be called from within a pardef. Slower, but must be called at least once before showing duplicate pardefs"]
    "---"
    ["Narrow Buffer to Given sdef" dix-narrow-to-sdef
     :help "Show only that part of the buffer which contains a given sdef, eg. work only on nouns for a while. Widen with `C-x n w' as per usual."]
    "---"
    ["Change Restriction of <e> (LR, RL, none)" dix-restriction-cycle]
    ["Go to Next Useful Position in the Buffer" dix-next]
    ["Go to Previous Useful Position in the Buffer" dix-previous]
    ("Replace Regexp Within..."
     ["Certain Elements" dix-replace-regexp-within-elt
      :help "Prompts for an element name"]
     ["<l> Elements" dix-replace-regexp-within-l]
     ["<r> Elements" dix-replace-regexp-within-r])
    ("Copy <e> and..."
     ["Keep Contents" dix-copy
      :help "Make a copy of the current <e> element"]
     ["Apply an LR Restriction" dix-LR-restriction-copy
      :help "Make a copy of the current <e> element"]
     ["Apply an RL Restriction" dix-RL-restriction-copy
      :help "Make a copy of the current <e> element"]
     ["Clear Contents" (dix-copy 'remove-lex)
      :keys "C-u C-c C"
      :help "Make a copy of the current <e> element"]
     ["Prepend kill-buffer into lm and <i>" dix-copy-yank
      :help "Make a copy of the current <e> element"])
    ["Turn one-word-per-line into XML using above <e> as template" dix-xmlise-using-above-elt
     :help "Write one word (or colon-separated word-pair) per line, then use the above <e> as a template to turn them into XML"]
    ["I-search Within lm's (rather buggy)" dix-word-search-forward]
    "---"
    ["Go to transfer rule number" dix-goto-rule-number]
    "---"
    ["Customize dix-mode" (customize-group 'dix)]
    ["Help for dix-mode" (describe-function 'dix-mode)
     :keys "C-h m"]
    ["Show dix-mode Version" (message "dix-mode version %s" dix-version)]))

;;;============================================================================
;;;
;;; Helpers
;;;

(defmacro dix-with-sexp (&rest body)
  "Execute `BODY' with `nxml-sexp-element-flag' set to true."
  (declare (indent 1) (debug t))
  `(let ((old-sexp-element-flag nxml-sexp-element-flag))
     (setq nxml-sexp-element-flag t)
     (let ((ret ,@body))
       (setq nxml-sexp-element-flag old-sexp-element-flag)
       ret)))

(defmacro dix-with-no-case-fold (&rest body)
  "Execute `BODY' with `case-fold-search' set to nil."
  (declare (indent 1) (debug t))
  `(let ((old-case-fold-search case-fold-search))
     (setq case-fold-search nil)
     ,@body
     (setq case-fold-search old-case-fold-search)))

(defun dix--completing-read (&rest args)
  "Call `dix-completing-read-function' on ARGS."
  (apply dix-completing-read-function args))

(defvar dix-parse-bound 10000
  "Max amount of chars (not lines) to parse through in dix xml operations.
Useful since dix tend to get huge.  Relative bound.  Decrease the
number if operations ending in \"No parent element\" take too
long.")

(put 'dix-bound-error 'error-conditions '(error dix-parse-error dix-bound-error))
(put 'dix-bound-error 'error-message "Hit `dix-parse-bound' when parsing")
(put 'dix-barrier-error 'error-conditions '(error dix-parse-error dix-barrier-error))
(put 'dix-barrier-error 'error-message "Hit barrier when parsing")

(defun dix-backward-up-element (&optional arg bound)
  "Modified from `nxml-backward-up-element' to include a search boundary.
Optional argument ARG says how many elements to move; won't go
past buffer position BOUND."
  (interactive "p")
  (or arg (setq arg 1))
  (if (< arg 0)
      (nxml-up-element (- arg))
    (condition-case err
	(while (and (> arg 0)
		    (< (point-min) (point)))
	  (let ((token-end (nxml-token-before)))
	    (goto-char (cond ((or (memq xmltok-type '(start-tag
						      partial-start-tag))
				  (and (memq xmltok-type
					     '(empty-element
					       partial-empty-element))
				       (< (point) token-end)))
			      xmltok-start)
			     ((nxml-scan-element-backward
			       (if (and (eq xmltok-type 'end-tag)
					(= (point) token-end))
				   token-end
				 xmltok-start)
			       t
			       bound)
			      xmltok-start)
			     (t (signal 'dix-bound-error "No parent element")))))
	  (setq arg (1- arg)))
      (nxml-scan-error
       (goto-char (cadr err))
       (apply 'error (cddr err))))))

(defun dix-up-to (eltname &optional barrier)
  "Move point to start of element `ELTNAME' (a string, eg. \"e\")
which we're looking at. Optional `BARRIER' is the outer element,
so we don't go all the way through the file looking for our
element (ultimately constrained by the variable
`dix-parse-bound').  Ideally `dix-backward-up-element' should
stop on finding another `ELTNAME' element."
  (nxml-token-after)
  (when (eq xmltok-type 'space)
    (goto-char (1+ (nxml-token-after)))
    (nxml-token-after))
  (goto-char xmltok-start)
  (let ((tok (xmltok-start-tag-qname))
	(bound (max (point-min)
		    (- (point) dix-parse-bound))))
    (while (not (or (equal tok eltname)
		    (equal tok barrier)
		    (equal tok (concat "<" eltname))))
      (dix-backward-up-element 1 bound)
      (nxml-token-after)
      (setq tok (xmltok-start-tag-qname)))
    (if (equal tok barrier)
	(signal 'dix-barrier-error (format "Didn't find %s" eltname)))))

(defvar dix-transfer-entities
  '((condition "and" "or" "not" "equal" "begins-with" "begins-with-list" "ends-with" "ends-with-list" "contains-substring" "in")
    (container "var" "clip")
    (sentence "let" "out" "choose" "modify-case" "call-macro" "append" "reject-current-rule")
    (value "b" "clip" "lit" "lit-tag" "var" "get-case-from" "case-of" "concat" "lu" "mlu" "chunk")
    (stringvalue "clip" "lit" "var" "get-case-from" "case-of")
    (choice "when" "otherwise"))
  "From transfer.dtd; interchunk/postchunk TODO.")

(defvar dix-transfer-elements
  '((def-macro sentence)
    (action sentence)
    (when sentence)
    (otherwise sentence)
    (test condition)
    (and condition)
    (or condition)
    (not condition)
    (equal value)
    (begins-with value)
    (ends-with value)
    (begins-with-list value)
    (ends-with-list value)
    (contains-substring value)
    (in value)
    (let value container)
    (append value)
    (modify-case stringvalue container)
    (concat value)
    (lu value)
    (tag value)
    (choose choice))
  "From transfer.dtd; interchunk/postchunk TODO.")

(defun dix-transfer-allowed-children (parent)
  "Return a list of strings of allowed child elts of PARENT."
  (let* ((parent (if (stringp parent) (intern parent) parent))
         (ent-types (cdr (assoc parent dix-transfer-elements))))
    (cl-reduce #'append
     (mapcar (lambda (type) (cdr (assoc type dix-transfer-entities)))
             ent-types))))

(defun dix-transfer-enclosing-allows (child)
  "Answer if the element we're inside can contain CHILD in a transfer file."
  (let ((parent (dix-enclosing-elt 'noerror)))
    (and parent
         (member child (dix-transfer-allowed-children parent)))))

(defun dix-enclosing-is-mono-section ()
  "Heuristically answer if the element we're inside is (monolingual) <section>.
A `dix-enclosing-elt' from outside an <e> in a <section> will
often hit `dix-parse-bound', in which case we just search back
for some hints."
  (let ((elt (dix-enclosing-elt 'noerror)))
    (or (and elt (equal elt "section"))
	(save-excursion
	  (and (re-search-backward " lm=\"\\|<pardef\\|</section>" nil 'noerror)
	       (equal " lm=\"" (match-string 0)))))))

(defun dix-enclosing-elt-helper (bound)
  "Get the qname of the enclosing element.
Will error if we don't find anything before the buffer position
BOUND."
  (dix-backward-up-element 1 bound)
  (nxml-token-after)
  (xmltok-start-tag-qname))

(defun dix-enclosing-elt (&optional noerror)
  "Return name of element we're in.
Optional argument NOERROR will make parse bound errors return
nil."
  (let ((bound (max (point-min)
		    (- (point) dix-parse-bound))))
    (save-excursion
      (if noerror
	  (condition-case nil
	      (dix-enclosing-elt-helper bound)
	    (dix-bound-error nil))
	(dix-enclosing-elt-helper bound)))))


(defun dix-pardef-at-point (&optional clean)
  "Give the name of the pardef we're in.
Optional argument CLEAN removes trailing __n and such."
  (save-excursion
    (dix-up-to "pardef" "pardefs")
    (re-search-forward "n=\"" nil t)
    (let ((pardef (symbol-name (symbol-at-point))))
      (if clean (replace-regexp-in-string
		 "\\([^/_]*\\)/?\\([^/_]*\\)__.*"
		 "\\1\\2"
		 pardef)
	pardef))))

(defun dix-lemma-at-point ()
  "Find the nearest lm attribute of this e element.
In a bidix, gives the contents of nearest of l/r."
  ;; TODO: handle <b>'s and <g>'s correctly, skipping <s>'s
  (if (dix-is-bidix)
      (dix-l/r-word-at-point) ;; bidix
    (save-excursion   ;; monodix
      (dix-up-to "e" "section")
      (re-search-forward "lm=\"\\([^\"]*\\)" nil t)
      (match-string-no-properties 1))))

(defun dix-i-at-point ()
  "Find the nearest i element of this e."
  ;; TODO less roundabout
  (let ((rs (dix-split-root-suffix)))
    (concat (car rs) (cdr rs))))

(defun dix-par-at-point ()
  "Find the nearest par element of this e."
  (save-excursion
    (dix-up-to "e" "section")
    (re-search-forward "<par[^/>]*n=\"\\([^\"]*\\)" nil t)
    (match-string-no-properties 1)))


(defun dix-pardef-suggest-at-point ()
  "Return a list of pardef names for suggestions.

First we look in the context around point (up to
`dix-parse-bound' in both directions), then append the full list
from <pardefs>.  Tries to be fast, so no actual XML parsing,
meaning commented out pardefs may be suggested as well."
  (save-restriction
    (widen)
    (let* ((par-rex "<par [^>]*n=['\"]\\([^'\"> ]+\\)")
	   (pardef-rex "<pardef [^>]*n=['\"]\\([^'\"> ]+\\)")
	   (pardefs-end (or (save-excursion
			      (re-search-backward "</pardefs>" nil 'noerror))
			    (point-min)))
	   (bound-above (max pardefs-end
			     (- (point) dix-parse-bound)))
	   (bound-below (min (+ (point) dix-parse-bound)
			     (point-max)))
	   pdnames)
      (save-excursion
	(while (re-search-backward par-rex bound-above 'noerror)
	  (cl-pushnew (match-string-no-properties 1) pdnames :test #'equal)))
      (save-excursion
	(while (re-search-forward par-rex bound-below 'noerror)
	  (cl-pushnew (match-string-no-properties 1) pdnames :test #'equal)))
      (save-excursion
	(goto-char pardefs-end)
	(while (re-search-backward pardef-rex nil 'noerror)
	  (cl-pushnew (match-string-no-properties 1) pdnames :test #'equal)))
      (nreverse pdnames))))

(defun dix-pardef-suggest-for (lemma)
  "Return a list of pardef names to suggest for `LEMMA'.

Names used near point are prioritised, and names marked for
lemma-suffixes that don't match the suffix of the lemma (e.g.
pardef \"foo/er__verb\" when the lemma is \"fooable\") are
filtered out."
  (cl-remove-if-not (lambda (par)
                      (if (string-match "/\\([^_]+\\)_" par)
                          (string-match (concat (match-string 1 par) "$") lemma)
                        'no-slash-so-match-all))
                    (dix-pardef-suggest-at-point)))

(defun dix-pardef-type-of-e ()
  "Give the part following `__' in a pardef name, or nil."
  (let ((par (dix-par-at-point)))
    (when (string-match "[^_]*__\\([^\"]*\\)" par)
      (match-string-no-properties 1 par))))

(defun dix-split-root-suffix ()
  "Give a pair of the <i>-contents and pardef <r>-contents.
The pardef <r>-contents are guessed by the letters following the
slash of the pardef.  Does not give the correct root of it's not
all contained within an <i> (eg. lemma pardefs will give wrong
roots)."
  (save-excursion
    (dix-up-to "e" "section")
    (let ((e-end (nxml-scan-element-forward (point))))
      (nxml-down-element 2)
      (cons (symbol-name (dix-with-sexp (sexp-at-point)))
	    (progn
	      (nxml-up-element)
	      (when (re-search-forward "n=\"[^/]*/\\([^_\"]*\\)[^\"]*\"" e-end 'noerror)
		(match-string-no-properties 1)))))))

(defun dix-get-attrib (attributes name)
  "Look in list ATTRIBUTES for one with name NAME (a string).
Assumes ATTRIBUTES of the same format as `xmltok-attributes'.
Return nil if no such attribute is found."
  (if attributes
      (if (equal name (buffer-substring-no-properties
		       (xmltok-attribute-name-start (car attributes))
		       (xmltok-attribute-name-end (car attributes))))
	  (car attributes)
	(dix-get-attrib (cdr attributes) name))))

(defun dix-attrib-start (attributes name)
  "Look in ATTRIBUTES for start position of attribute NAME, or nil if no such.
Assumes ATTRIBUTES is of the format of `xmltok-attributes'."
  (let ((attrib (dix-get-attrib attributes name)))
    (when attrib (xmltok-attribute-value-start attrib))))

(defvar dix-interesting
  '(;; dix:
    ("clip" "pos" "side" "part")
    ("e" "lm" "r" "c")
    ("par" "n")
    ("section" "id" "type")
    ("pardef" "n")
    ("s" "n")
    ;; transfer:
    ("sdef" "n")
    ("b" "pos")
    ("with-param" "pos")
    ("call-macro" "n")
    ("def-macro" "n" "npar")
    ("cat-item" "lemma" "tags" "name")
    ("attr-item" "lemma" "tags")
    ("list-item" "v")
    ("list" "n")
    ("def-attr" "n")
    ("def-cat" "n")
    ("def-list" "n")
    ("def-var" "n")
    ("pattern-item" "n")
    ("chunk" "name" "case" "namefrom")
    ("var" "n")
    ("lit" "v")
    ("lit-tag" "v")
    ;; modes:
    ("pipeline")
    ("mode" "name" "install")
    ("program" "name")
    ("file" "name")
    ;; lrx:
    ("match" "lemma" "tags")
    ("select" "lemma" "tags")
    ("seq" "n")
    ("def-seq" "n")
    ;; cross-model:
    ("cross-action" "id" "a")
    ("v" "n")
    ("t" "n")
    ;; tsx:
    ("def-label" "name" "closed")
    ("def-mult" "name")
    ("tags-item" "tags" "lemma")
    ("label-item" "label")
    ("tagger" "name"))
  "Association list of elements and which attributes are considered interesting.
Used by `dix-next'.")

(defvar dix-skip-empty
  '("dictionary" "alphabet" "sdefs" "pardefs" "lu" "p" "e" "tags" "chunk" "tag" "pattern" "rule" "action" "out" "b" "def-macro" "choose" "when" "test" "equal" "not" "otherwise" "let" "forbid" "label-sequence" "tagset")
  "Skip past these elements when using `dix-next'.
They'll not be skipped if they have interesting attributes as defined by
`dix-interesting', however.")
;;; TODO: skip <[lr]><g><b/> and go to nearest CDATA in e.g. <l><g><b/>for</g></l>

(defmacro dix-filter (pred lst)
  "Test PRED on each elt of LST, removing non-true values."
  `(delq nil
         (mapcar (lambda (elt) (when (funcall ,pred elt) elt))
                 ,lst)))

(defun dix-nearest (pivot backward &rest args)
  "Find the element numerically nearest PIVOT.
If BACKWARD, we we want only elements of ARGS that are lower than
PIVOT, otherwise only higher."
  (let ((cmp (if backward '< '>))
	(nearest (if backward 'max 'min)))
    (let ((OK (dix-filter (lambda (x) (and x (funcall cmp x pivot)))
                          args)))
      (when OK (apply nearest OK)))))

(defun dix-nearest-interesting (attributes pivot backward interest)
  "Find the nearest \"interesting\" element.

This will return the position of the nearest member of list
INTEREST which is also a member of ATTRIBUTES (in the format of
`xmltok-attributes') but not crossing PIVOT.  If BACKWARD, we we
want only elements of ARGS that are lower than PIVOT, otherwise
only higher."
  (apply 'dix-nearest pivot backward
	 (mapcar (lambda (attname)
		   (dix-attrib-start attributes attname))
		 interest)))

(defun dix-next-one (&optional backward)
  "Move forward one interesting element.
Helper for `dix-next' (move back if BACKWARD non-nil).
TODO: handle pardef entries too; make non-recursive."

  (cl-flet ((move (spot)
                  (if (if backward (< spot (point)) (> spot (point)))
                      (goto-char spot)
                    (progn (forward-char (if backward -1 1))
                           (dix-next-one backward)))))

    (let* ((token-end (nxml-token-before))
           (token-next (if backward
                           xmltok-start
                         (1+ token-end)))
           (qname (xmltok-start-tag-qname))
           (interest (cdr (assoc qname dix-interesting)))
           (near-int (dix-nearest-interesting xmltok-attributes
                                              (point)
                                              backward
                                              interest)))
      (cond ((eq (point) (if backward (point-min) (point-max)))
             t)

            ((memq xmltok-type '(prolog comment))
             (goto-char token-next)
             (dix-next-one backward))

            (near-int			; interesting attribute
             (move near-int))		; to go to

            ((or interest	; interesting element but no next interesting attribute
                 (member qname dix-skip-empty)) ; skip if empty
             (move token-next)
             (dix-next-one backward))

            ((memq xmltok-type '(space data end-tag))
             (and (goto-char token-next)
                  (not (and backward ; need to goto these elts from data
                            (nxml-token-before) ; before looping on:
                            (member (xmltok-start-tag-qname) '("r" "l" "i"))))
                  (dix-next-one backward)))

            ;; TODO: should instead while-loop until the next member of
            ;; dix-interesting, or maybe the default should be to go to
            ;; the next _attribute_, whatever it is?
            (t (move token-end))))))


(defun dix-compile-suffix-map (partype)
  "Build a hash map where keys are sorted lists of suffixes in
pardefs, eg. '(\"en\" \"ing\" \"s\"), and the value is a list of
the pardef names containing these suffixes.

Argument PARTYPE is eg. adj, vblex, vblex_adj, ..., and is the
string following \"__\", thus assumes you keep to the Apertium
standard.  Also assumes there is no \"_\" before \"__\" in pardef
names."
  (let ((suffmap (make-hash-table :test 'equal)))
    (save-excursion
      (goto-char (point-min))
      ;; find all pardefs of `partype' in the file:
      (while (re-search-forward
	      (concat "pardef[^n>]*n=\"\\([^\"]*__" partype "\\)\"") nil 'noerror)
	(let ((pardef (match-string-no-properties 1))
	      (sufflist (dix-compile-sorted-suffix-list)))
	  (puthash sufflist
		   (cons pardef (gethash sufflist suffmap)) suffmap))))
    suffmap))

(defvar dix-suffix-maps nil
  "Internal association list used to store compiled suffix maps;
keys are symbols formed from the string `partype' (see
`dix-compile-suffix-map' and interactive function
`dix-find-duplicate-pardefs').")
(make-variable-buffer-local 'dix-suffix-maps)

(defun dix-get-pardefs (sufflist suffmap)
  "Get the list of pardefs in SUFFMAP which have the list of suffixes SUFFLIST.

See `dix-compile-suffix-map' for more information."
  (gethash (sort sufflist 'string-lessp) suffmap))

(defun dix-compile-sorted-suffix-list ()
  "Make lookup keys for `dix-compile-suffix-map' and `dix-get-pardefs'."
  (save-excursion
    (let (sufflist)
      (condition-case nil
	  (progn (dix-up-to "pardef" "pardefs"))
	(dix-parse-error (dix-goto-pardef)))
      ;; find all suffixes within this pardef:
      (let ((end (save-excursion (dix-with-sexp (forward-sexp))
				 (point))))
	(while (re-search-forward "<l>\\([^<]*\\)</l>" end 'noerror)
	  (when (match-string 1)
	    (setq sufflist (cons (match-string-no-properties 1) sufflist)))))
      (sort sufflist 'string-lessp))))

(defun dix-assoc-delete-all (key alist)
  "Delete all instances of KEY in ALIST.
Returns a copy (does not modify the original list)."
  (if alist
      (if (equal (caar alist) key)
	  (dix-assoc-delete-all key (cdr alist))
	(cons (car alist)
	      (dix-assoc-delete-all key (cdr alist))))))

(defun dix-invert-alist (a)
  "Invert the alist A so values become keys and keys values.
Values should of course be unique.  The new values will lists."
  (apply #'append
         (mapcar (lambda (entry)
                   (mapcar (lambda (c) (list c (car entry)))
                           (cdr entry)))
                 a)))

;;;============================================================================
;;;
;;; Schemas / validation
;;;
(defcustom dix-schema-locating-files nil
  "List of schema locating files.
Used by `dix-schema' to populate `rng-schema-locating-files'.
If nil, a default schema will be added."
  :type '(repeat file)
  :group 'dix)

(defun dix-schemas ()
  "Add default Apertium schemas.xml to locating rules.
If possible, adds rules for files installed through package
manager, falling back to files installed using 'sudo make
install'.

To override, copy the schemas.xml file distributed with dix.el,
edit the paths, and add the path to the list
`dix-schema-locating-files'."
  (if dix-schema-locating-files
      (setq rng-schema-locating-files (append dix-schema-locating-files
                                              rng-schema-locating-files))
    (let ((source-dir (file-name-directory
                       (concat            ; nil => empty string
                        (find-lisp-object-file-name #'dix-schemas nil))))
          (rulefile (if (file-exists-p "/usr/share/lttoolbox/dix.rnc")
                        "schemas.xml"
                      "local-schemas.xml")))
      (add-to-list 'rng-schema-locating-files (concat source-dir rulefile)))))

(add-hook 'dix-load-hook #'dix-schemas)


;;;============================================================================
;;;
;;; Alignment
;;;
(defcustom dix-rp-align-column 28
  "Column to align pardef <r> elements to with `align'."
  :type 'integer
  :group 'dix)
(defcustom dix-rb-align-column 44
  "Column to align bidix <r> elements to with `align'."
  :type 'integer
  :group 'dix)
(defcustom dix-i-align-column 25
  "Column to align <i> elements to with `align'."
  :type 'integer
  :group 'dix)
(defcustom dix-ep-align-column 2
  "Column to align pardef <e> elements to with `align'.
Not yet implemented, only used by `dix-LR-restriction-copy'."
  :type 'integer
  :group 'dix)
(defcustom dix-pp-align-column 12
  "Column to align pardef <p> elements to with `align'."
  :type 'integer
  :group 'dix)
(defcustom dix-pb-align-column 10
  "Column to align bidix <p> (and <re>) elements to with `align'."
  :type 'integer
  :group 'dix)

(defun dix-add-align-rule (name regexp column)
  (add-to-list 'align-rules-list
	       `(,name
		 (regexp . ,regexp)
		 (tab-stop . nil)
		 (spacing . 0)
		 (group . 1)
		 (modes . '(nxml-mode))
		 (column . ,column))))
(add-hook
 'align-load-hook
 (lambda ()
   (dix-add-align-rule
    'dix-rp-align "\\s-+\\(\\s-*\\)<r>" 'dix-rp-align-column)
   (dix-add-align-rule                  ;
    'dix-rb-align "\\(\\s-*\\)<r>" 'dix-rb-align-column)
   (dix-add-align-rule
    'dix-i-align "\\(\\s-*\\)<i" 'dix-i-align-column)
   (dix-add-align-rule
    'dix-pb-align "^\\S-*\\(\\s-*\\)<\\(p\\|re\\)>" 'dix-pb-align-column)
   (dix-add-align-rule
    'dix-pp-align "^\\s-+\\S-*\\(\\s-*\\)<p>" 'dix-pp-align-column)))

;;;============================================================================
;;;
;;; Interactive functions
;;;

(defun dix-find-duplicate-pardefs (&optional recompile)
  "Find all pardefs with this list of suffixes.

'Suffixes' are contents of <l> elements.  If there are several of
them they might be duplicates.  Optional prefix argument
RECOMPILE forces a re-check of all pardefs.

Uses internal function `dix-compile-suffix-map' which assumes
that pardefs are named according to the regular Apertium scheme,
eg. \"lik/e__vblex\" (ie. all pardefs of the same group have
\"__\" before the group name, and there are no \"_\" before
\"__\").

Returns the list of pardef names."
  (interactive "P")
  (let* ((partype
	  (save-excursion
	    (condition-case nil
		(progn (dix-up-to "pardef" "pardefs"))
	      (dix-parse-error (dix-goto-pardef)))
	    (re-search-forward
	     (concat "pardef[^n>]*n=\"[^\"]*__\\([^\"]*\\)" ) nil 'noerror)
	    (match-string-no-properties 1)))
	 (foundmap (cdr (assoc-string partype dix-suffix-maps))))
    (let* ((suffmap
	    (if (or recompile (not foundmap))
		(dix-compile-suffix-map partype)
	      foundmap))
	   (pardefs (dix-get-pardefs (dix-compile-sorted-suffix-list)
				     suffmap)))
      (when (or recompile (not foundmap))
	(setq dix-suffix-maps (dix-assoc-delete-all partype dix-suffix-maps))
	(add-to-list 'dix-suffix-maps (cons partype suffmap) 'append))
      (message (prin1-to-string pardefs))
      pardefs)))

(defvar dix-vr-langs nil "List of language codes (strings) allowed in the vr attribute of this dictionary.")
(defvar dix-vl-langs nil "List of language codes (strings) allowed in the vl attribute of this dictionary.")
(put 'dix-vr-langs 'safe-local-variable 'listp)
(put 'dix-vl-langs 'safe-local-variable 'listp)

(defun dix-get-vr-vl ()
  "A cons of attribute key (vr/vl) and value (nno, nob, …); or nil if none such.
Assumes we don't have both vr and vl at the same time.
Assumes we've just done (dix-up-to \"e\" \"pardef\")"
  (save-excursion
    (when (re-search-forward " v\\([rl]\\)=\"\\([^\"]+\\)\"" (nxml-token-after) 'noerror 1)
      (cons (match-string 1)
            (match-string 2)))))

(defun dix-v-cycle ()
  "Cycle through possible values of the `vr' or `vl' attributes.

Only affects the <e> element at point.

Doesn't yet deal with elements that specify both vr and vl.

For this to be useful, put something like this at the end of your file:

<!--
Local Variables:
dix-vr-langs: (\"nno\" \"nob\")
End:
-->"
  (interactive)
  (save-excursion
    (dix-up-to "e" "pardef")
    (let* ((def-dir (if dix-vr-langs "r" "l"))
           (langs (list (cons "r" dix-vr-langs)
                        (cons "l" dix-vr-langs)))
           (old	(dix-get-vr-vl)) ; find what, if any, restriction we have already
           (dir (if old (car old) def-dir))
           (old-lang (when old (cdr old)))
           (dir-langs (cdr (assoc dir langs)))
           (next (car-safe (if old-lang
                               (cdr (member old-lang dir-langs))
                             dir-langs)))
           (new (if next
                    (format " v%s=\"%s\"" dir next)
                  "")))
      ;; restrict:
      (forward-word)
      (if old (delete-region (match-beginning 0)
			     (match-end 0)))
      (insert new)
      (unless (looking-at ">") (just-one-space))
      ;; formatting, remove whitespace:
      (goto-char (nxml-token-after))
      (unless (looking-at "<")
	(goto-char (nxml-token-after)))
      (delete-horizontal-space)
      (cond  ((looking-at "<i") (indent-to dix-i-align-column))
	     ((save-excursion (search-forward "</pardef>" nil 'noerror 1))
	      (indent-to dix-pp-align-column))
	     ((looking-at "<p\\|<re") (indent-to dix-pb-align-column))))))

(defun dix-restriction-cycle (&optional dir)
  "Cycle through possible values of the `r' attribute.

Only affects the <e> element at point.

Optional argument DIR is a string, either \"\", \"LR\" or
\"RL\"."
  (interactive)
  (save-excursion
    (dix-up-to "e" "pardef")
    (let* ((old		     ; find what, if any, restriction we have:
	    (save-excursion
	      (if (re-search-forward " r=\"\\(..\\)\"" (nxml-token-after) 'noerror 1)
		  (match-string 1))))
	   (dir (if dir dir
		  (if old		; find our new restriction:
		      (if (equal old "LR")
			  "RL"	; "LR" => "RL"
			"")	; "RL" =>  ""
		    "LR")))	;  ""  => "LR"
	   (new (if (equal dir "") ""
		  (concat " r=\"" dir "\""))))
      ;; restrict:
      (forward-word)
      (if old (delete-region (match-beginning 0)
			     (match-end 0)))
      (insert new)
      (unless (looking-at ">") (just-one-space))
      ;; formatting, remove whitespace:
      (goto-char (nxml-token-after))
      (unless (looking-at "<")
	(goto-char (nxml-token-after)))
      (delete-horizontal-space)
      (cond  ((looking-at "<i") (indent-to dix-i-align-column))
             ((save-excursion (search-forward "</pardef>" nil 'noerror 1))
              (indent-to dix-pp-align-column))
             ((looking-at "<p\\|<re") (indent-to dix-pb-align-column))))))

(defun dix--swap-outer-tag (elt newtag)
  "Change the outer tag of ELT to NEWTAG."
  (replace-regexp-in-string
   "^<[^ >]*" (concat "<" newtag)
   (replace-regexp-in-string
    "</[^>]*>$" (concat "</" newtag ">")
    elt)))

(defun dix--xml-end-point ()
  "End position of xml-element starting here."
  (save-excursion (nxml-forward-element 1) (point)))

(defun dix-LR-restriction-copy (&optional RL)
  "Make an LR-restricted copy of the dix element we're looking at.
A prefix argument makes it an RL restriction."
  (interactive "P")
  (save-excursion
    (dix-copy)
    (let ((dir (if RL "RL" "LR")))
      (dix-restriction-cycle dir)))
  (dix-up-to "e" "pardef")
  (if (dix-is-bidix)
      (progn
        ;; move point to end of relevant word:
        (nxml-down-element 2)
        (when RL (nxml-forward-element))
        (nxml-down-element 1)
        (goto-char (nxml-token-after)))
    (when (save-excursion
            (re-search-forward "<i>" (dix--xml-end-point) 'noerror))
      ;; turn <i> into <p><l><r>:
      (nxml-forward-element 1)
      (nxml-down-element 1)
      (unless (looking-at-p "<i>")
        (goto-char (nxml-token-after)))
      (let ((i (buffer-substring-no-properties
                (point)
                (dix--xml-end-point))))
        (insert "<p>"
                (dix--swap-outer-tag i "l")
                (dix--swap-outer-tag i "r")
                "</p>")
        (delete-region (point) (dix--xml-end-point))
        (nxml-backward-element 1)))))

(defun dix-RL-restriction-copy ()
  "Make an RL-restricted copy of the dix element we're looking at."
  (interactive)
  (dix-LR-restriction-copy 'RL))

(defun dix-copy (&optional remove-lex)
  "Make a copy of the Apertium element we're looking at.
Optional prefix argument REMOVE-LEX removes the contents of the
lm attribute and <i> or <p> elements."
  (interactive "P")
  ;; TODO: find the first one of these: list-item, e, def-var, sdef, attr-item, cat-item, clip, pattern-item,
  (if (not (dix-is-dix))
      (message "dix-copy only implemented for .dix/.metadix files, sorry.")
    (dix-up-to "e" "pardef")
    (let ((beg (or (re-search-backward "^[\t ]*" (line-beginning-position) 'noerror) (point)))
          (origend (1+ (save-excursion
                         (goto-char (nxml-scan-element-forward (point)))
                         (or (re-search-forward "[\t ]*$" (line-end-position) 'noerror) (point))))))
      (goto-char origend)
      (insert (buffer-substring-no-properties beg origend))
      (let ((copyend (point)))
        (when remove-lex
          (save-excursion
            (goto-char origend)
            (save-restriction
              (narrow-to-region origend copyend)
              (while (re-search-forward "lm=\\\"[^\\\"]*\\\"" nil 'noerror 1)
                (replace-match "lm=\"\""))
              (goto-char (point-min))
              (while (re-search-forward "<i>.*</i>" nil 'noerror 1)
                (replace-match "<i></i>"))
              (goto-char (point-min))
              (while (re-search-forward "<p>.*</p>" nil 'noerror 1)
                (replace-match "<p><l></l><r></r></p>")))))
        ;; Put point at next useful spot, but don't move past this element:
        (goto-char origend)
        (dix-next)
        (if (> (point) copyend) (goto-char origend))))))



(defun dix-copy-yank ()
  "Make a copy of the dix element we're looking at, and yank into
the beginning of the lm and <i>."
  ;; TODO: remove old data
  (interactive)
  (dix-copy)
  (dix-next 1)
  (yank)
  (dix-next 1)
  (yank))

(defun dix-l-at-point-reg ()
  "Return <l> of <e> at point as pair of buffer positions."
  (save-excursion
    (dix-up-to "e" "pardef")
    (nxml-down-element 2)
    (cons (dix-token-start) (nxml-scan-element-forward (point)))))

(defun dix-r-at-point-reg ()
  "Return <r> of <e> at point as pair of buffer positions."
  (save-excursion
    (dix-up-to "e" "pardef")
    (nxml-down-element 2)
    (nxml-forward-element 1)
    (cons (dix-token-start) (nxml-scan-element-forward (point)))))

(defun dix-first-cdata-of-elt (pos)
  "Return first available CDATA of elt after POS as string.
Note: Skips <b/>'s and turns them into spaces."
  (save-excursion
    (goto-char pos)
    (nxml-down-element 1)
    (let ((beg (point)))
      (dix-with-sexp (forward-sexp))
      ;; There may be more, with <b/>'s:
      (while (and (nxml-token-after)
                  (equal "b" (xmltok-start-tag-qname)))
        (nxml-forward-element)
        (dix-with-sexp (forward-sexp)))
      (replace-regexp-in-string "<b[^>]*>"
                                " "
                                (buffer-substring beg (point))))))

(defun dix-l-word-at-point ()
  "Return first available CDATA of <l> of <e> at point as string."
  (dix-first-cdata-of-elt (car (dix-l-at-point-reg))))

(defun dix-r-word-at-point ()
  "Return first available CDATA of <r> of <e> at point as string."
  (dix-first-cdata-of-elt (car (dix-r-at-point-reg))))

(defun dix-l/r-at-point-reg ()
  "Return nearest region of <l>/<r> as a tagged pair of buffer positions.
The return value is of the form '(TAG . (BEG . END)) where TAG is
the symbol `l' or `r', while BEG and END are buffer positions."
  (let* ((l (dix-l-at-point-reg))
         (r (dix-r-at-point-reg))
         (nearest (cond
                   ((< (point) (cdr l)) 'l)
                   ((> (point) (car r)) 'r)
                   ((< (- (point)
                          (cdr l))
                       (- (car r)
                          (point)))
                    'l)
                   (t 'r))))
    (if (eq nearest 'l)
        (cons nearest l)
      (cons nearest r))))

(defun dix-l/r-word-at-point ()
  "Return first available CDATA of nearest <l> or <r> as string."
  (let* ((tr (dix-l/r-at-point-reg))
         (reg (cdr tr))
         (beg (car reg)))
    (dix-first-cdata-of-elt beg)))


(defvar dix-char-alist
  ;; TODO: Emacs<23 uses utf8, latin5 etc. while Emacs>=23 uses unicode
  ;; for internal representation; use (string< emacs-version "23")
  '((?a 225)
    (?A 193)
    (?s 353)
    (?S 352)
    (?t 359)
    (?T 358)
    (?n 331)
    (?N 330)
    (?d 273)
    (?D 272)
    (?c 269)
    (?C 268)
    (?a 2273)
    (?A 2241)
    (?z 382)
    (?Z 381)
    (?s 331937)
    (?S 331936)
    (?t 331943)
    (?T 331942)
    (?n 331883)
    (?N 331882)
    (?d 331825)
    (?D 331824)
    (?c 331821)
    (?C 331820))
  "Sámi alphabet:
ášertŧuiopåŋđæølkjhgfdsazčcvbnmÁŠERTŦUIOPÅŊĐÆØLKJHGFDSAZČCVBNM")

(put 'dix-char-table 'char-table-extra-slots 0) ; needed if 0?

(defvar dix-asciify-table
  ;; TODO: seems like this has to be eval'ed after loading something else...
  (let ((ct (make-char-table 'dix-char-table)))
    (dolist (lst dix-char-alist ct)
      (mapc (lambda (x) (aset ct x (car lst))) (cdr lst))))
  "Converts Sámi characters into ascii equivalent.")

(defun dix-asciify (str)
  "Used before sorting to turn á into a, etc in STR."
  (let ((cpos 0))
    (while (< cpos (length str))
      (let ((tr (aref dix-asciify-table (elt str cpos))))
	(when tr (aset str cpos tr)))
      (cl-incf cpos)))
  str)

(defun dix-token-start ()
  "Give the position of the start of the following element.
Useful after e.g. `nxml-down-element' if there's whitespace."
  (if (looking-at "<")
      (point)
    (nxml-token-after)))

(defun dix-sort-e-by-l (from-end reverse beg end &optional by-r)
  "Sort region alphabetically by contents of <l> element.

Interactive argument means sort from the reversed
contents (similarly to the shell command `rev|sort|rev')..
Assumes <e> elements never occupy more than one line.

Called from a program, there are for arguments:  FROM-END non-nil
means sort by reversed contents, REVERSE non-nil means descending
order of lines, BEG and END are the region to sort.  The variable
`sort-fold-case' determines whether alphabetic case affects the
sort order.

Sorts by <r> element if optional argument BY-R is true.

Note: will not work if you have several <e>'s per line!"
  (interactive "P\ni\nr")
  (let ((endrec (lambda ()
	          (dix-up-to "e")
	          (nxml-forward-element)
	          (re-search-forward "\\s *" (line-end-position) 'noerror)
	          (let ((next-tok (nxml-token-after))) ; skip comments before eol:
	            (while (and (eq xmltok-type 'comment)
			        (<= next-tok (line-end-position)))
	              (goto-char next-tok)
	              (re-search-forward "\\s *" (line-end-position) 'noerror)
	              (setq next-tok (nxml-token-after))))))
        (startkey (lambda ()
	  (nxml-down-element 1)
	  (let ((slr (dix-get-slr xmltok-attributes)))
	    (nxml-down-element 1)
	    (let* ((lstart (point))
		   (lend (progn (nxml-forward-element) (point)))
		   (rstart (dix-token-start))
		   (rend (progn (nxml-forward-element) (point)))
		   (l (dix-asciify (buffer-substring-no-properties lstart lend)))
		   (r (dix-asciify (buffer-substring-no-properties rstart rend))))
	      (if by-r
		  (list r l)
		(list l slr r))))))
        (nextrec (lambda ()
	           (goto-char (nxml-token-after))
	           (re-search-backward "\\s *" (line-beginning-position) 'noerror)))
        (endkey nil)
        (predicate (if from-end
                       (lambda (a b)
                         (string< (mapconcat #'reverse a)
                                  (mapconcat #'reverse b)))
                     (lambda (a b)
                       (string< (concat a) (concat b))))))
    (save-excursion
      (save-restriction
        (narrow-to-region beg end)
        (goto-char (point-min))
        (let ;; make `end-of-line' and etc. to ignore fields:
	    ((inhibit-field-text-motion t))
	  (sort-subr reverse
	             nextrec
	             endrec
	             startkey
                     endkey
                     predicate))))))

(defun dix-sort-e-by-r (from-end reverse beg end)
  "Sort <e> elements by the contents of <l>.
See `dix-sort-e-by-l' for meaning of arguments FROM-END, REVERSE,
BEG and END."
  (interactive "P\ni\nr")
  (dix-sort-e-by-l from-end reverse beg end 'by-r))

(defun dix-get-slr (attributes)
  "Give the string value of the slr attribute if it's set, else \"0\".

ATTRIBUTES is of the format of `xmltok-attributes'.  Should
probably be padded since we use it for sorting, but so far there
are never slr's over 10 anyway …"
  (let ((att (dix-get-attrib attributes "slr")))
    (if att
	(buffer-substring-no-properties (xmltok-attribute-value-start att)
					(xmltok-attribute-value-end att))
      "0")))

(defun dix-sort-pardef (reverse)
  "Sort a pardef using `dix-sort-e-by-r'.

If REVERSE, sorts in opposite order."
  (interactive "P")
  (save-excursion
    (let (beg)
      (dix-up-to "pardef" "pardefs")
      ;; get beginning of first elt within pardef:
      (setq beg (save-excursion (goto-char (nxml-token-after))
				(nxml-token-after)))
      ;; nxml-token-before is beginning of <pardef>; set xmltok-start
      ;; to beginning of </pardef>:
      (if (nxml-scan-element-forward (nxml-token-before))
	  (dix-sort-e-by-r reverse beg xmltok-start)))))

(defun dix-reverse-lines (beg end)
  "Reverse each line in the region.
Used by `dix-suffix-sort'.  If called non-interactively, reverse
each full line from BEG to END (inclusive, never reverses part of
a line)."
  (interactive "r")
  (save-excursion
    (if (and (>= beg (line-beginning-position))
	     (<= end (line-end-position)))
	(dix-reverse-region (line-beginning-position)
			    (line-end-position))
      (save-restriction
	(narrow-to-region beg end)
	(goto-char (point-min))
	(while (< (point) (point-max))
	  (dix-reverse-region (line-beginning-position)
			      (line-end-position))
	  (forward-line))))))

(defun dix-reverse-region (beg end)
  "Reverse the text between positions BEG and END in the buffer.
Used by `dix-reverse-lines'."
  (interactive "r")
  (let ((line (buffer-substring beg end)))
    (delete-region beg end)
    (insert (apply 'string (reverse (string-to-list line))))))

(defun dix-suffix-sort (beg end)
  "Sort the region by the reverse of each line.
Useful for finding compound words which could have the same paradigm.
BEG and END bound the region to sort when called programmatically."
  (interactive "r")
  (dix-reverse-lines beg end)
  (sort-lines nil beg end)
  (dix-reverse-lines beg end))

(defun dix-replace-regexp-within-elt (regexp to-string eltname &optional delimited start end)
  "Does exactly what `query-replace-regexp' does, except it
restricts REGEXP and TO-STRING to text within ELTNAME elements.
Note: this function does not ensure that TO-STRING is free from
instances of the end ELTNAME, so it's easy to break if you so
wish."
  (interactive
   (let ((common (query-replace-read-args
		  (if (and transient-mark-mode mark-active)
		      "Query replace regexp in region within elements" "Query replace regexp within elements")
		  t))
	 (eltname (read-from-minibuffer "Element name: ")))
     (list (nth 0 common) (nth 1 common) eltname (nth 2 common)
	   (if (and transient-mark-mode mark-active) (region-beginning))
	   (if (and transient-mark-mode mark-active) (region-end)))))
  (perform-replace (concat "\\(<" eltname ">.*\\)" regexp "\\(.*</" eltname ">\\)")
		   (concat "\\1" to-string "\\2")
		   t t delimited nil nil start end))

(defun dix-replace-regexp-within-l (regexp to-string &optional delimited start end)
  "Call `dix-replace-regexp-within-elt' on <l> elements."
  (interactive
   (let ((common (query-replace-read-args
		  (if (and transient-mark-mode mark-active)
		      "Query replace regexp in region within <l>'s" "Query replace regexp within <l>'s")
		  t)))
     (list (nth 0 common) (nth 1 common) (nth 2 common)
	   (if (and transient-mark-mode mark-active) (region-beginning))
	   (if (and transient-mark-mode mark-active) (region-end)))))
  (dix-replace-regexp-within-elt regexp to-string "l" delimited start end))

(defun dix-replace-regexp-within-r (regexp to-string &optional delimited start end)
  "Call `dix-replace-regexp-within-elt' on <r> elements."
  (interactive
   (let ((common (query-replace-read-args
		  (if (and transient-mark-mode mark-active)
		      "Query replace regexp in region within <r>'s" "Query replace regexp within <r>'s")
		  t)))
     (list (nth 0 common) (nth 1 common) (nth 2 common)
	   (if (and transient-mark-mode mark-active) (region-beginning))
	   (if (and transient-mark-mode mark-active) (region-end)))))
  (dix-replace-regexp-within-elt regexp to-string "r" delimited start end))


(defvar dix-search-substring nil
  "Set by `dix-word-search-forward'.")

(defun dix-is-transfer ()
  "True if buffer file name transfer-like (rather than dix)."
  (string-match-p "[.]..+-..+[.]t[0-9]x" (or (buffer-file-name) "")))

(defun dix-is-lrx ()
  "True if buffer file name lrx-like (rather than dix)."
  (string-match-p "[.]..+-..+[.]\\(?:meta\\)?lrx" (or (buffer-file-name) "")))

(defun dix-is-bidix ()
  "True if buffer file name bidix-like (rather than monodix)."
  (string-match-p "[.]..+-..+[.]dix" (or (buffer-file-name) "")))

(defun dix-is-dix ()
  "True if buffer file name bidix-like (rather than monodix)."
  (string-match-p ".+[.]\\(?:meta\\)?dix" (or (buffer-file-name) "")))

(defun dix-word-search-forward (&optional whole-word)
  "Incremental word-search for dix files.

In monodix, searches only within lm attributes, in bidix,
searches only between > and < symbols.  If optional prefix
argument WHOLE-WORD is given, you have to type the whole word
in to get a (correct) hit, otherwise you can search for partial
words.

TODO:
- Check if this can be rewritten as a `isearch-filter-predicate'
- Figure out why two backspaces are needed (seems to 'temporarily
  fail' when searching)
- Unless we're doing a substring search, we should probably not
  do an incremental search (that is, not search until user
  presses enter), but `word-search-forward' isn't good
  enough (doesn't highlight, no way to C-s to the next hit...)"
  (interactive "P")
  (setq dix-search-substring (not whole-word))
  (isearch-mode
   'forward 'regexp
   (lambda ()
     (let* ((bidix (dix-is-bidix))
	    (l (if bidix ">" "lm=\""))
	    (r (if bidix "<" "\""))
	    (affix (when dix-search-substring
                     "[^<\"]*")))
       (setq isearch-string
	     (concat l affix
                     (replace-regexp-in-string " "
                                               "\\\\( \\\\|<b/>\\\\)"
                                               isearch-message)
                     affix r))
       (goto-char isearch-opoint)
       (setq isearch-forward t)	; o/w the first C-s goes backward, for some reason
       (isearch-search)
       (isearch-push-state)
       (isearch-update)))))

(defun dix-find-rhs-mismatch ()
  "Find possible mismatches in <r> elements.

This is e.g. a pardef where two <e>'s have different suffixes in
their <r>'s.

Only stops at the first mismatch within one pardef."
  (interactive)
  (cl-flet* ((next-rhs ()
                       (re-search-forward "<r>\\([^<]*\\)<\\|\\(</pardef>\\)" nil t))
             (next-pardef ()
                          (and (search-forward "pardef" nil t) (next-rhs))))
    (let ((keep-looking (next-pardef))	; find first hit
          (last-rhs (match-string 1)))
      ;; Check next ones for mismatches:
      (while keep-looking
        (if (equal (match-string 2) "</pardef>")
            (setq keep-looking (next-pardef) ; skip to next <pardef>
                  last-rhs (match-string 1))
          (if (equal (match-string 1) last-rhs)
              (next-rhs)			; skip to next <e>
            (setq keep-looking nil))))
      ;; Echo results:
      (if (match-string 1)
          (and (goto-char (match-end 1))
               (message
                (concat "Possible mismatch in <r>: " last-rhs " vs " (match-string 1))))
        (message "No mismatches discovered.")))))

(defun dix-next (&optional step)
  "Move to the next 'interesting' element/attribute.

Moves forward STEP steps (default 1) between the important
places (lm attribute, <i>/<r>/<l> data, n attribute of <par>/<s>;
and then onto the next <e> element).  See also `dix-previous'.
Interestingness is defined by `dix-interesting'."
  (interactive "p")
  (let* ((step (if step step 1))
	 (backward (< step 0)))
    (when (> (abs step) 0)
      (dix-next-one backward)
      (dix-next (if backward (1+ step) (1- step))))))

(defun dix-previous (&optional step)
  "Move backward to the next 'interesting' element.

Moves STEP steps (default 1).  See also `dix-next'."
  (interactive "p")
  (dix-next (- (if step step 1))))

(defun dix-nearest-pdname (origin)
  "Return the pardef-name nearest ORIGIN within an <e> element."
  (save-excursion
    (dix-up-to "e")
    (let* ((e-end (nxml-scan-element-forward (nxml-token-before)))
	   (pdname (and (re-search-forward "par\\s *n=\"\\([^\"]*\\)\"" e-end)
			(match-string-no-properties 1))))
      (while (and (re-search-forward "<par\\s *n=\"\\([^\"]*\\)\"" e-end 'noerror)
		  (< (match-beginning 0) origin))
	(setq pdname (match-string-no-properties 1)))
      pdname)))

(declare-function imenu--make-index-alist "imenu" (&optional noerror))
(autoload #'imenu--make-index-alist "imenu")

(defun dix-find-definition ()           ; TODO: convert to xref!
  "Go to definition of thing at point."
  (interactive)
  (cond ((dix-is-transfer)
         (let ((sym (thing-at-point 'symbol)))
           (if (assoc sym (imenu--make-index-alist))
               (imenu sym)
             (call-interactively #'imenu))))
        (t
         (dix-goto-pardef))))

(defun dix-goto-pardef (&optional pdname)
  "Call from an entry to go to its pardef.

Optional argument PDNAME specified an exact pardef name to go to;
otherwise the name nearest point is used.  Mark is pushed so you
can go back with \\[pop-to-mark-command]."
  (interactive)
  (let* ((pdname (or pdname (dix-nearest-pdname (point))))
	 (pos (save-excursion
		(goto-char (point-min))
		(when (re-search-forward
		       (concat "<pardef *n=\"\\(" (regexp-quote pdname) "\\)\"")
                       nil t)
		  (match-beginning 0)))))
    (if pos
	(progn
	  (push-mark)
	  (goto-char pos)
	  (unless (equal (match-string 1) pdname)
	    (message "WARNING: pardef-names don't quite match: \"%s\" and \"%s\"" pdname (match-string 1))))
      (message "Couldn't find pardef %s" pdname))))

(defun dix-view-pardef ()
  "Show pardef in other window.

The pardef is just inserted into a new buffer where you can
e.g. edit at will and then paste back.  The nice thing is that
for each call of this function, the pardef is added to the
*dix-view-pardef* buffer, so you get a temp buffer where you can
eg. collapse pardefs."
  ;; TODO: would it be better to `clone-indirect-buffer-other-window'
  ;; with a buffer restriction, so we could edit the pardef without
  ;; having to copy-paste it back?
  (interactive)
  (save-excursion
    (save-restriction
      (widen)
      (dix-goto-pardef)
      (let* ((beg (point))
	     (end (1+ (nxml-scan-element-forward beg)))
	     (pardef (buffer-substring beg end)))
	(save-selected-window
	  (pop-to-buffer "*dix-view-pardef*")
	  (insert pardef)
	  (nxml-mode)
	  (dix-mode 1)
	  (goto-char (point-max))	; from `end-of-buffer'
	  (overlay-recenter (point))
	  (recenter -3))))))


(defun dix-goto-rule-number (num)
  "Go to <rule> number NUM in the file.

When called interactively, asks for a rule number (or uses the
prefix argument)."
  (interactive "NRule number: ")
  (let ((found nil)
	(cur num))
    (save-excursion
      (goto-char (point-min))
      (while (and (> cur 0)
		  (setq found (dix-rule-forward)))
	(setq cur (- cur 1))))
    (if found
	(goto-char found)
      (message "Couldn't find rule number %d" num))))

(defun dix-rule-forward ()
  "Move point to the next transfer <rule>.

Return point if we can find a non-commented <rule> before the end
of the buffer, otherwise nil"
  (let ((found-a-rule (re-search-forward "<rule[ >]" nil t))
        (keep-looking (and (nxml-token-before) (eq xmltok-type 'comment))))
    (while (and found-a-rule
                keep-looking)
      (setq found-a-rule (re-search-forward "<rule[ >]" nil t)
            keep-looking (and (nxml-token-before) (eq xmltok-type 'comment))))
    (and found-a-rule
         (not keep-looking)
         (point))))

(defun dix-find-next-file (&optional reverse)
  "Guess a reasonable \"next\" file and open it.
E.g. from transfer foo-bar.t2x, go to foo-bar.t3x; wrapping
around to t1x if no higher exists.  If REVERSE, find \"previous\"
file."
  ;; TODO: It would be nice to go between bidix and monodix, but
  ;; what's a logical interface? also, discovery requires parsing
  ;; config.log's or similar, and there can be vr's leading to
  ;; multiple monodix for either direction …
  (interactive "P")
  (let* ((file (buffer-file-name))
         (dir (file-name-directory file))
         (base (file-name-base file))
         (ext (file-name-extension file))
         (butext (concat (file-name-as-directory dir) base "."))
         (get-next (if reverse #'1- #'1+))
         (get-prev (if reverse #'1+ #'1-))
         (full-t?x (lambda (n)
                     (let ((path (concat butext "t" (number-to-string n) "x")))
                       (and (file-exists-p path)
                            path))))
         (tNx (and (string-match "^t\\([0-9]\\)x$" ext)
                   (string-to-number (match-string 1 ext))))
         (t1x (and tNx
                   (let ((nn tNx)) ; find the lowest/highest existing t?x
                     (while (funcall full-t?x (funcall get-prev nn))
                       (setq nn (funcall get-prev nn)))
                     (funcall full-t?x nn))))
         (t1+x (and tNx
                    (funcall full-t?x (funcall get-next tNx))))
         ;; TODO: alternatively `git ls-files|grep .dix`:
         (dix (when (string-match "\\.\\(proper-\\)?\\([a-z]+\\)\\.dix$" file)
                (let* ((is-proper (match-string 1 file))
                       (lang (match-string 2 file))
                       (path-next (concat (replace-regexp-in-string
                                           "\\.[^.]+$" ""
                                           (file-name-sans-extension file))
                                          (if is-proper
                                              "."
                                            ".proper-")
                                          lang ".dix")))
                  (and (file-exists-p path-next)
                       (not (equal file path-next))
                       path-next))))
         (next-file (cl-find-if-not #'not               ; find first non-nil
                                    (list t1+x
                                          t1x
                                          dix))))
    (if next-file
        (find-file next-file)
      (message "dix.el couldn't guess as to what's the logical next file"))))

(defun dix-find-previous-file ()
  "Guess a reasonable \"previous\" file and open it.
E.g. from transfer foo-bar.t2x, go to foo-bar.t1x; wrapping
around to t3x if no lower exists."
  (interactive)
  (dix-find-next-file 'previous))


(defvar dix-modes
  '((nn-nb ("lt-proc"    "/l/n/nn-nb.automorf.bin")
	   ("cg-proc" "/l/n/nn-nb.rlx.bin")
	   ("apertium-tagger -g" "/l/n/nn-nb.prob")
	   ("apertium-pretransfer")
	   ("apertium-transfer" "/l/n/apertium-nn-nb.nn-nb.t1x" "/l/n/nn-nb.t1x.bin" "/l/n/nn-nb.autobil.bin")
	   ("lt-proc -g" "/l/n/nn-nb.autogen.bin"))
    (nb-nn ("lt-proc"    "/l/n/nb-nn.automorf.bin")
	   ("cg-proc" "/l/n/nb-nn.rlx.bin")
	   ("apertium-tagger -g" "/l/n/nb-nn.prob")
	   ("apertium-pretransfer")
	   ("apertium-transfer" "/l/n/apertium-nn-nb.nb-nn.t1x" "/l/n/nb-nn.t1x.bin" "/l/n/nb-nn.autobil.bin")
	   ("lt-proc -g" "/l/n/nb-nn.autogen.bin"))))
(make-variable-buffer-local 'dix-modes)

(defun dix-analyse (&optional no-disambiguate)
  "Very bare-bones at the moment.

TODO: read modes.xml instead of those using those dix-path*
variables, and allow both directions (although should have some
option to override the modes.xml reading)."
  (interactive "P")
  (save-selected-window
    (let ((modes dix-modes)
	  (word (dix-nearest-greppable))
	  last-output)
      (pop-to-buffer "*dix-analysis*")
      (dolist (mode modes)
	(insert "==> " (symbol-name (car mode)) " <==\n")
	(setq last-output word)
	(dolist (cmd (cdr mode))
	  (let ((cmdstr (mapconcat 'concat cmd " ")))
	    (insert " " cmdstr ":\n")
	    (setq last-output
		  (substring		; trim off final newline
		   (shell-command-to-string
		    (concat "echo '" last-output "' | " cmdstr))
		   0 -1))
 	    (insert last-output "\n\n")
	    (when (and no-disambiguate (or (string= "lt-proc" (car cmd))
					   (string= "lt-proc -w" (car cmd))))
	      (insert (setq last-output (dix-analysis-split last-output)) "\n"))))))
    (nxml-mode)
    (toggle-truncate-lines 0)
    (goto-char (point-max))		; from `end-of-buffer'
    (overlay-recenter (point))
    (recenter -3)))

(defun dix-analysis-split (ambig)
  (let* ((first (string-match "/" ambig))
	 (surface (substring ambig (string-match "\\^" ambig) first))
	 (analyses (substring ambig first (string-match "\\$" ambig))))
    (mapconcat (lambda (analysis) (concat surface "/" analysis "$"))
	       (split-string analyses "/" 'omitnulls) " ")))

(defun dix-rstrip (whole end)
  "Remove substring END from string WHOLE and return the result."
  (if (string= end
	       (substring whole
			  (- (length whole) (length end))))
      (substring whole 0 (- (length whole) (length end)))
    (error (concat "The string \"" end "\" does not end \"" whole "\""))))

(defvar dix--entry-tries nil
  "Cached result of `dix--mk-partype-trie' 'entry per partype.")
(make-variable-buffer-local 'dix--entry-tries)

(defvar dix--pardef-tries nil
  "Cached result of `dix--mk-partype-trie' 'pardef per partype.")
(make-variable-buffer-local 'dix--pardef-tries)

(defun dix--mk-partype-trie (partype entry-or-pardef)
  "Make a trie for looking up paradigms/entries from reverse lemmas of PARTYPE.
Only looks at words above point.  Values are paradims iff ENTRY-OR-PARDEF is 'pardef."
  (let ((s (buffer-substring-no-properties (point-min) (point)))
        (e-or-m-group (if (eq entry-or-pardef 'pardef)
                          2
                        0)))
    (with-temp-buffer
      (insert s)
      (goto-char (point-min))
      (keep-lines (concat partype "\""))
      (let ((trie (strie-new))
            (exp (format "<e .*lm=\"\\([^\"]+\\)\".*n=\"\\([^\"]+%s\\)\".*</e>" partype)))
        (while (re-search-forward exp nil 'noerror)
          (strie-add trie (reverse (match-string 1)) (match-string e-or-m-group)))
        trie))))

(defun dix--partrie-best-par (trie input)
  "Get the most used pardef for suffix-matches on INPUT from pardef TRIE.
TRIE is from `dix--mk-partype-trie' 'pardef."
  ;; TODO: Not used; could be useful for ranking if we have many
  ;; matches from dix--partrie-find-entry-template
  (let ((cur trie)
        (found nil)
        (inp (reverse input))
        (pardefs (make-hash-table :test #'equal)))
    (while (and cur (> (length inp) 2))
      (message "\ninp: %S cur: %s" inp 'cur)
      (setq found cur cur (strie-get-child cur (substring inp 0 1)))
      (setq inp (substring inp 1)))
    (when found
      (let ((prefixes (strie-complete found ""))
            (best-score 0)
            (best-par nil))
        (mapc (lambda (pre)
                (let ((par (strie-get found pre)))
                  (puthash par (+ 1 (gethash par pardefs 0))
                           pardefs)))
              prefixes)
        (maphash (lambda (par score)
                   (when (> score best-score)
                       (setq best-score score
                             best-par par)))
                 pardefs)
        (cons (reverse inp) best-par)))))

(defun dix--partrie-find-entry-template (trie input)
  "Get a template entry for suffix-matches on INPUT from pardef TRIE.
TRIE is from `dix--mk-partype-trie' 'entry."
  (let* ((cur trie)
         (found nil)
         (inp (reverse input))
         (lhs inp))
    (while (and cur (> (length inp) 2))
      (setq found cur
            cur (strie-get-child cur (substring inp 0 1))
            lhs inp
            inp (substring inp 1)))
    (when found
      (let ((prefixes (dix--partrie-keep-usable
                       found
                       (strie-complete found ""))))
        (when prefixes
          (let* ((matched (substring input (length lhs)))
                 (prefix (car prefixes)))
            (list (reverse lhs)
                  (strie-get found prefix)
                  (reverse prefix)
                  matched)))))))

(defun dix--partrie-keep-usable (node prefixes)
  "Keep only those PREFIXES reachable from NODE that match `dix--guess-is-usable'."
  (cl-remove-if-not (lambda (prefix)
                      (dix--guess-is-usable (strie-get node prefix) (reverse prefix)))
                    prefixes))

(defun dix--guess-is-usable  (e-template oldlhs)
  "True iff we can strip OLDLHS out of E-TEMPLATE to use it for guessing."
  (string-match-p (format "<e[^>]*>\\s *<i>%s"
                          (replace-regexp-in-string " " "<b/>" oldlhs))
                  e-template))

(defun dix-guess-pardef (&optional refresh-partype-trie)
  "Guess a dix entry for word at point based on above entries.

Example usage:

You want to add the noun \"øygruppe\" to your .dix.  Go to the
last of the noun entries in the file, write the word on a line of
its own, and run this function.  It'll look at all nouns, and
find the one that shares the longest suffix, e.g. \"gruppe\", and
use that as a template, creating an entry like:

<e lm=\"øygruppe\">    <i>øygrupp</i><par n=\"lø/e__n\"/></e>

On first run, it creates a cache of all entries of the
immediately above part of speech (using paradigm suffixes to find
the main PoS, e.g. \"__n\" in the example above).

If REFRESH-PARTYPE-TRIE, the cache is updated, otherwise
it's reused.  There's one cache per PoS, so when adding verbs
you'll use the \"__vblex\" cache etc.

You can also add mwe's like

setje# fast

and get them turned into

<e lm=\"setje fast\"> <i>set</i><par n=\"set/je__vblex\"/><p><l><b/>fast</l><r><g><b/>fast</g></r></p></e>

assuming there's a line like

<e lm=\"setje\">      <i>set</i><par n=\"set/je__vblex\"/></e>

somewhere above.

Assumes paradigms have names ending in \"__PoS\", and entries are
single-line.  Will not work well unless morphology is based on suffixes."
  (interactive "P")
  (require 'strie)
  (let* ((queue-start (save-excursion (search-forward "#" (line-end-position) 'noerror)))
	 (queue (when queue-start
		  (replace-regexp-in-string
		   "^#" ""
		   (buffer-substring-no-properties queue-start (line-end-position)))))
	 ;; rhs of point is the part we search for, the lhs and queue are particular to this word
	 (rhs-end (if queue-start
		      (1- queue-start)
		    (line-end-position)))
         (partype (save-excursion
                    (and (re-search-backward "<par n=\"[^\"]*\\(__[^\"]*\\)") ; do-error
                         (match-string-no-properties 1))))
         (lm2entrie (or (and (not refresh-partype-trie)
                             (cdr (assoc partype dix--entry-tries  #'equal)))
                        (let ((tr (dix--mk-partype-trie partype 'entry)))
                          (setq dix--entry-tries
                                (cons (cons partype tr)
                                      (assoc-delete-all partype dix--entry-tries #'equal)))
                          tr)))
         (lemh (buffer-substring-no-properties (line-beginning-position) rhs-end))
	 (match (dix--partrie-find-entry-template lm2entrie lemh)))
    (if match
	(let* ((lhs (cl-first match))
               (rhs (substring lemh (length lhs)))
               (e (cl-second match))
               (oldlhs (cl-third match))
               (oldlm (concat oldlhs (cl-fourth match))))
          (delete-region (line-beginning-position) (line-end-position))
          (insert e)
	  (when queue
	    (save-excursion
	      (nxml-backward-down-element)
	      (insert (concat "<p><l>"
			      (replace-regexp-in-string " " "<b/>" queue)
			      "</l><r><g>"
			      (replace-regexp-in-string " " "<b/>" queue)
			      "</g></r></p>"))))
	  (nxml-backward-single-balanced-item)
	  (dix-next)
	  (let* ((lmbound (progn (nxml-token-after)
				 (nxml-attribute-value-boundary (point)))))
	    (delete-region (car lmbound) (cdr lmbound))
	    (insert (concat lemh queue))
	    (dix-next) ; go into following <i>, delete prefix of template if possible:
            (let ((end (+ (point) (length oldlhs))))
              (if (or (eq (point) end)
                      (and (string= (xmltok-start-tag-qname) "i")
	                   (string= oldlhs (buffer-substring-no-properties (point) end))
	                   (or (delete-region (point) end)
                               t)))
                  (progn
	            (unless (string= (xmltok-start-tag-qname) "i")
	              (nxml-backward-up-element)
	              (insert "<i></i>")
	              (backward-char 4))
	            (insert (replace-regexp-in-string " " "<b/>" lhs))
	            (beginning-of-line) (insert (concat "<!-- " oldlm " -->")) (end-of-line))
                (message "No fitting entry template found :-/")))))
      (message "No fitting word found :-/"))))

(defun dix-add-par ()
  "Just add a <par>-element, guessing a name from nearest above par."
  (interactive)
  (let ((par-guess
         (save-excursion
           (or
            (when (re-search-backward "<par n=\"\\([^\"]*\\)" nil 'noerror 1)
              (match-string-no-properties 1))
            (when (re-search-backward "<pardef n=\"\\([^\"]*\\)" nil 'noerror 1)
              (match-string-no-properties 1))))))
    (dix-up-to "e" "section")
    (nxml-forward-element)
    (nxml-backward-down-element)
    (let ((p (+ (point) 8)))
      (insert (format "<par n=\"%s\"/>" par-guess))
      (goto-char p))))

(defun dix-add-s ()
  "Just add an <s>-element, guessing a name from nearest previous s.
The guesser will first try to find a tag from the same
context (ie. a tag that was seen after the tag we're adding a tag
after)."
  (interactive)
  (let ((reg (cdr (dix-l/r-at-point-reg))))
    ;; (elt (buffer-substring-no-properties (+ 1 (car reg))
    ;;                                      (+ 2 (car reg))))
    ;; Move so we're inside the l or r:
    (when (or (< (point) (car reg))
              (> (point) (cdr reg)))
      (goto-char (car reg)))
    ;; If we were inside an s, move before it:
    (nxml-token-after)
    (when (equal (xmltok-start-tag-qname) "s")
      (nxml-up-element))
    ;; Go to start of next s, or end of l/r:
    (if (re-search-forward "<s +[^>]+/>" (cdr reg) 'noerror 1)
        (goto-char (match-beginning 0))
      (goto-char (- (cdr reg) 4)))
    (let ((s-guess
           (save-excursion
             (or
              (when (re-search-backward (concat
                                         ;; First try finding a tag following the tag we're at:
                                         (regexp-quote (buffer-substring (- (point) 13)
                                                                         (point)))
                                         "<s n=\"\\([^\"]*\\)")
                                        nil 'noerror 1)
                (match-string-no-properties 1))
              (when (re-search-backward "<s n=\"\\([^\"]*\\)" nil 'noerror 1)
                (match-string-no-properties 1))
              (when (re-search-backward "<sdef n=\"\\([^\"]*\\)" nil 'noerror 1)
                (match-string-no-properties 1))
              "sg")))
          (p (+ (point) 6)))
      (insert (format "<s n=\"%s\"/>" s-guess))
      (goto-char p))))


(defun dix-point-after-> ()
  "True if point is exactly after the > symbol."
  (equal (buffer-substring-no-properties (1- (point)) (point))
         ">"))

(defun dix-space ()
  "This should return a space, unless we're inside the data area
of <g>, <r>, <l> or <i>, in which case we want a <b/>. If we're
in the attribute of a <par> or <pardef>, we insert an underscore.

A bit hacky I guess, but I don't want to require nxhtml just to
get nxml-where-path, and reimplementing an XML Path seems rather
too much work for this."

  (cl-flet ((in-elt (names)	; nxml-token-before must be called before this
                    (let ((eltname (save-excursion
                                     (goto-char xmltok-start)
                                     (when (equal xmltok-type 'data)
                                       (nxml-token-before)
                                       (goto-char xmltok-start))
                                     (xmltok-start-tag-qname))))
                      (and eltname (member eltname names)))))

    (nxml-token-before)
    (cond ((and (or (eq xmltok-type 'data)
                    (and (memq xmltok-type '(start-tag empty-element))
                         (dix-point-after->)))
                (in-elt '("g" "b" "r" "l" "i" "ig")))
           "<b/>")
          ((and (catch 'in-attr
                  (dolist (attr xmltok-attributes)
                    (if (and (xmltok-attribute-value-start attr)
                             (>= (point) (xmltok-attribute-value-start attr))
                             (xmltok-attribute-value-end   attr)
                             (<= (point) (xmltok-attribute-value-end   attr))
                             (equal (xmltok-attribute-local-name attr) "n"))
                        (throw 'in-attr t))))
                (in-elt '("par" "pardef")))
           "_")
          (t
           " "))))

(defun dix-insert-space ()
  "Insert a `dix-space' at point."
  (interactive)
  (insert (dix-space)))

(defcustom dix-hungry-backspace nil
  "Delete whole XML elements (<b/>, comments) with a single press of backspace.
Set to nil if you don't want this behaviour."
  :type 'boolean
  :group 'dix)

(defun dix-backspace ()
  "Delete a character backward, unless we're looking at the end
of <b/> or a comment, in which case we delete the whole element.

Note: if we're looking at the relevant elements, prefix arguments
are ignored, while if we're not, a prefix argument will be passed
to the regular `delete-backward-char'."
  (interactive)
  (if (and dix-hungry-backspace
	   (nxml-token-before)
	   (or
	    (and (eq xmltok-type 'empty-element)
		 (equal (xmltok-start-tag-qname) "b"))
	    (and (eq xmltok-type 'comment)
		 (dix-point-after->))))
      (delete-region (point) xmltok-start)
    (call-interactively 'delete-backward-char)))

(defun dix-< (literal)			; not in use yet
  "Insert < in space or unclosed tags, otherwise move to the beginning of the element."
  (interactive "*P")
  (if literal
      (self-insert-command (prefix-numeric-value literal))
    (nxml-token-after)
    (cond ((memq xmltok-type '(space data not-well-formed partial-start-tag))
	   (insert-char ?< 1))
	  (t (progn (nxml-up-element)
		    (dix-with-sexp (backward-sexp)))))))
(defun dix-> (literal)
  "Insert > in space or unclosed tags, otherwise move to the end of the element."
  (interactive "*P")
  (if literal
      (self-insert-command (prefix-numeric-value literal))
    (nxml-token-before)
    (cond ((memq xmltok-type '(space not-well-formed partial-start-tag))
	   (insert-char ?> 1))
	  (t (nxml-up-element)))))

(defun dix-xmlise-using-above-elt ()
  "Turn colon-separated line into xml using above line as template.

Simple yasnippet-like function to turn a plain list into <e>
entries.  Write a bunch of words, one word per line, below a
previous <e> entry, then call this function to apply that entry
as a template on the word list.

Example (with point somewhere in the word list):


<e lm=\"baa\">      <i>ba</i><par n=\"ba/a__n\"/></e>
bada
bam bada
nana:mana

=>

<e lm=\"baa\">      <i>ba</i><par n=\"ba/a__n\"/></e>
<e lm=\"bada\">      <i>bad</i><par n=\"ba/a__n\"/></e>
<e lm=\"bam bada\">      <i>bam<b/>bad</i><par n=\"ba/a__n\"/></e>
<e lm=\"mana\">      <p><l>nan</l><r>man</r></p><par n=\"ba/a__n\"/></e>



Bidix example:

<e><p><l>ja<b/>nu<b/>ain<s n=\"Adv\"/></l><r>og<b/>så<b/>videre<s n=\"adv\"/></r></p></e>
kánske:kanskje
lahka:slags

=>

<e><p><l>ja<b/>nu<b/>ain<s n=\"Adv\"/></l><r>og<b/>så<b/>videre<s n=\"adv\"/></r></p></e>
<e><p><l>kánske<s n=\"Adv\"/></l><r>kanskje<s n=\"adv\"/></r></p></e>
<e><p><l>lahka<s n=\"Adv\"/></l><r>slags<s n=\"adv\"/></r></p></e>"
  ;; TODO: remove the ugly
  ;; TODO: support for turning :<: and :>: into restrictions
  (interactive)
  (nxml-token-before)
  (when (eq xmltok-type 'data)
    (let* ((template-basis-end (save-excursion (goto-char xmltok-start)
					       ;; TODO: skip (include) comments
					       (re-search-backward "[ \t]*$" (line-beginning-position) 'no-errors)
					       (forward-line)
					       (point)))
	   (template-basis-start (save-excursion (nxml-backward-single-balanced-item)
						 (re-search-backward "^[ \t]*" (line-beginning-position) 'no-errors)
						 (point)))
	   (template-basis (buffer-substring-no-properties template-basis-start template-basis-end))
	   (template
	    ;; Create a format string like <e lm="%"><i>%s</i><par n="foo"/></e>
	    ;; TODO: might be more understandable with regex string-match?
	    (with-temp-buffer
	      (insert template-basis)
	      (goto-char (point-min))
	      (cond ((save-excursion (search-forward "<i>" (line-end-position) 'noerror))
		     (delete-region
		      (goto-char (match-end 0))
		      (save-excursion (search-forward "</i>" (line-end-position))
				      (match-beginning 0)))

		     (insert "%s"))
		    ((save-excursion (search-forward "<l>" (line-end-position) 'noerror))
		     (delete-region
		      (goto-char (match-end 0))
		      (save-excursion (re-search-forward "<s \\|</l>" (line-end-position))
				      (match-beginning 0)))

		     (insert "%s")
		     (search-forward "<r>" (line-end-position))
		     (delete-region
		      (match-end 0)
		      (save-excursion (re-search-forward "<s \\|</r>" (line-end-position))
				      (match-beginning 0)))
		     (insert "%s")))
	      (goto-char (point-min))
	      (when (save-excursion (search-forward " lm=\"" (line-end-position) 'noerror))
		(delete-region
		 (goto-char (match-end 0))
		 (save-excursion (search-forward "\"" (line-end-position))
				 (match-beginning 0)))
		(insert "%s"))
	      (buffer-substring-no-properties (point-min) (point-max))))
	   (lmsuffix
	    ;; regexp to remove from <i>'s if <i> is shorter than lm in the template:
	    (concat (and (string-match "<i>\\(.*\\)</i>"
				       template-basis)
			 (string-match (concat " lm=\"" (match-string 1 template-basis) "\\([^\"]+\\)\"")
				       template-basis)
			 (match-string 1 template-basis))
		    "$"))
	   (inlist-start (save-excursion (nxml-token-before)
                                         (goto-char xmltok-start)
                                         (re-search-forward "[^ \t\n]")
                                         (match-beginning 0)))
	   (inlist-end (save-excursion (goto-char (nxml-token-after))
                                       (re-search-backward "[^ \t\n]")
                                       (match-end 0)))
	   (inlist (split-string
		    (dix-trim-string (buffer-substring-no-properties
				      inlist-start
				      inlist-end))
		    "\n"
		    'omit-nulls))
	   (outlist (mapcar
		     (lambda (line)
		       ;; if there's no `:', use the whole line for both <l> and <r>,
		       ;; if there's one `:', use that to split into <l> and <r>
		       (let* ((lr (split-string line ":"))
                              (has-lm (string-match " lm=\"%s\"" template))
                              ;; If it seems we're in monodix, strip the # from the <l>:
                              (l-plain (if has-lm
                                           (replace-regexp-in-string "#" "" (car lr))
                                         (car lr)))
                              (r-plain (if (cdr lr)
                                           (cadr lr)
                                         (car lr)))
			      (l (replace-regexp-in-string lmsuffix ""
							   (dix-xmlise-l-r-to-xml l-plain)))
			      (r (replace-regexp-in-string lmsuffix ""
							   (dix-xmlise-l-r-to-xml r-plain))))
			 (when (cl-caddr lr) (error "More than one : in line: %s" line))
			 (format (if (equal l r)
				     template
				   ;; both <l> and <r> in input, perhaps change <i/> to <l/>...<r/>:
				   (replace-regexp-in-string "<i>%s</i>"
							     "<p><l>%s</l><r>%s</r></p>"
							     template))
				 (if has-lm (replace-regexp-in-string "#" "" r-plain) l)
				 (if has-lm l r)
				 r)))
		     inlist)))
      ;; Delete the old inlist, and insert the new outlist:
      (delete-region inlist-start inlist-end)
      (insert
       (if (eq (length outlist) 1)
           (string-trim (car outlist))
         (apply #'concat outlist))))))

(defun dix-xmlise-l-r-to-xml (s)
  "Handle spaces and the # symbol in `dix-xmlise-using-above-elt'.
The S is what turns into the left or right string."
  (replace-regexp-in-string
   " "
   "<b/>"
   (replace-regexp-in-string
    "#\\(.*\\)"
    "<g>\\1</g>"
    s)))

(defun dix-trim-string (s)
  "Trim leading and trailing spaces, tabs and newlines off S."
  (cond ((not (stringp s)) nil)
	((string-match "^[ \t\n]*\\(\\(?:.\\|\n\\)*[^ \t\n]+\\)[ \t\n]*" s)
	 (match-string 1 s))
	(t s)))

(defvar dix-expansion-left nil
  "Cons of the tmpfile used to store the expansion, and the
timestamp of the file last time we expanded it, as given
by (sixth (file-attributes dix-monodix-left)).")

(defvar dix-monodix-left "/l/n/nno/apertium-nno.nno.dix"
  "Set to the default monodix you want when running `dix-expand'.")

(defun dix-expansion-sentinel (_proc change-str)
  (when (string= "finished\n" change-str)
    (message "Expansion updated")
    (kill-buffer "*lt-expand*")))

(defun dix-update-expansion (expansion monodix update-expansion)
  "Due to emacs variable scoping, we have to include a function
`update-expansion' that updates the `expansion' variable with a
new tmpfile and `monodix' timestamp."
  (if (or (not expansion)
	  (and expansion
	       (not (equal (cl-sixth (file-attributes monodix))
			   (cdr expansion)))))
      (let ((tmpfile (dix-trim-string
		      (shell-command-to-string "mktemp -t expansion.XXXXXXXXXX"))))
	(message "Expansion out of date with left monodix, hang on...")
	(if (and (file-attributes tmpfile) (file-attributes monodix))
	    (progn
	      (shell-command
	       (concat "lt-expand " monodix " " tmpfile " &") "*lt-expand*")
	      (funcall update-expansion tmpfile (cl-sixth (file-attributes monodix)))
	      (set-process-sentinel (get-buffer-process "*lt-expand*") #'dix-expansion-sentinel))
	  (error "mktemp command failed: %s" tmpfile)))
    (message "Expansion up-to-date")))

(defun dix-update-expansions ()
  (interactive)
  (dix-update-expansion dix-expansion-left dix-monodix-left
			(lambda (file time)
			  (setq dix-expansion-left (cons file time)))))

(defun dix-expand (lemma pos)
  ;; TODO work-in-progress
  (shell-command (concat "grep ':\\([>]:\\)*" lemma "<" pos ">' " (car dix-expansion-left))))

(defun dix-expand-possibilities (tags)
  "There should be no leading < in `tags', but you can have
several with >< between them."
  (shell-command (concat "grep ':\\([>]:\\)*[^<]*<" tags "' " (car dix-expansion-left)
			 " | sed 's/.*:[^\\<]*\\</</' | sort | uniq")))

(defun dix-narrow-to-sdef-narrow (sdef sec-start sec-end)
  (goto-char sec-start)
  (search-forward (concat "<s n=\"" sdef "\""))
  (search-backward "<e")
  (beginning-of-line)
  (narrow-to-region (point)
		    (save-excursion
		      (goto-char sec-end)
		      (search-backward (concat "<s n=\"" sdef "\""))
		      (search-forward "</e")
		      (end-of-line)
		      (point))))

(defun dix-narrow-to-sdef (&optional no-widen)
  "Narrow buffer to a region between the first and the last
occurence of a given sdef in a given section; lets you
tab-complete on sdefs and sections.

Optional prefix argument `no-widen' lets you narrow even more in
on a previously narrowed buffer (the default behaviour for
`narrow-to-region'), otherwise the buffer is widened first."
  ;; TODO: DTRT in monodix too!
  (interactive "P")
  (dix-with-no-case-fold
      (let (sdefs)
        (save-excursion ;; find all sdefs
          (save-restriction (widen)
                            (goto-char (point-min))
                            (while (re-search-forward
                                    "<sdef[^>]*n=\"\\([^\"]*\\)\"" nil 'noerror)
                              (cl-pushnew (match-string-no-properties 1) sdefs :test #'equal))))
        (let ((sdef (dix--completing-read "sdef/POS-tag: " sdefs nil 'require-match))
              id start end sections)
          (save-excursion ;; find all sections
            (save-restriction (widen)
                              (goto-char (point-min))
                              (while (setq start (re-search-forward
                                                  "<section[^>]*id=\"\\([^\"]*\\)\"" nil 'noerror))
                                (setq id (match-string-no-properties 1))
                                (setq end (re-search-forward "</section>"))
                                (if (search-backward (concat "<s n=\"" sdef "\"") start 'noerror)
                                    (cl-pushnew (list id start end) sections :test #'equal)))))
          ;; narrow to region between first and last occurrence of sdef in chosen section
          (let* ((ids (mapcar 'car sections))
                 (id (if (cdr sections)
                         (dix--completing-read "Section:" ids nil 'require-match
                                               (if (cdr ids) nil (car ids)))
                       (caar sections)))
                 (section (assoc id sections)))
            (unless no-widen (widen))
            (dix-narrow-to-sdef-narrow sdef (cl-second section) (cl-caddr section)))))))

(defun dix-move-to-top ()
  "Move the current element to the top of the file.
Can be useful when sorting out entries."
  (interactive)
  (save-excursion
    (if (and transient-mark-mode mark-active)
	(exchange-point-and-mark)
      (progn
	(dix-up-to "e")
	(push-mark (nxml-scan-element-forward (point)))))
    (when (re-search-backward "\\S " nil t)
      (forward-char))
    (let* ((beg (point))
	   (end (mark))
	   (region (buffer-substring beg end)))
      (delete-region beg end)
      (goto-char (point-min))
      (end-of-line)
      (insert region)))
  (re-search-forward "\\S "))

(defcustom dix-dixfiles '("*.dix" "dev/*dix")
  "String list of dictionary files to grep with `dix-grep-all'.
Can contain shell globs."
  :type '(list string)
  :group 'dix)

(defcustom dix-completing-read-function completing-read-function
  "Like `completing-read-function', but only used in dix functions."
  :type 'function
  :group 'dix)

(defvar dix-greppable
  '(;; dix:
    ("e" "lm" "l" "r" "i")
    ("par" "n")
    ("pardef" "n"))
  "Elements and which attributes are considered interesting for grepping.
Association list used by `dix-grep-all'.")

(defvar dix-grep-fns
  '(;; dix:
    ("e" . dix-lemma-at-point)
    ("l" . dix-l-word-at-point)
    ("r" . dix-r-word-at-point)
    ("i" . dix-i-at-point)
    ("par" . dix-par-at-point)
    ("pardef" . dix-pardef-at-point))
  "Elements and which functions to find the greppable symbol at point.
Association list used by `dix-grep-all'.")


(defun dix-nearest-greppable ()
  (let* ((_token-end (nxml-token-before))
         (greppable (save-excursion
                      (let ((dix-interesting dix-greppable))
                        (dix-next)
                        (dix-previous)
                        (let ((g (assoc (xmltok-start-tag-qname) dix-grep-fns)))
                          (when g
                            (cons (car g) (funcall (cdr g)))))))))
    (if greppable
        greppable
      (message "Nothing greppable found here (see variables dix-greppable and dix-grep-fns).")
      nil)))

(defun dix-grep-all (&optional include-this)
  "Show all usages of this pardef in related dictionaries.
Related dictionaries are represented by the (customizable) string
`dix-dixfiles'.  Unless optional argument INCLUDE-THIS is given,
the current file is excluded from the results."
  (interactive "P")
  (let* ((greppable (dix-nearest-greppable))
         ;; TODO: if par/pardef, want to search only par/pardef, and so on
         (_found-in (car greppable))
         (needle (if (and transient-mark-mode mark-active)
                     (buffer-substring (region-beginning)
                                       (region-end))
                   (cdr greppable)))
         (needle-attrib (replace-regexp-in-string "<b/>" " " needle))
         (needle-cdata (replace-regexp-in-string " " "<b/>" needle))
         ;; TODO: exclude current file?
         (files (mapconcat #'identity (dix-existing-dixfiles include-this) " ")))
    (grep (format "grep -nH -e %s -e %s %s"
                  (shell-quote-argument (format "lm=\"%s\"" needle-attrib))
                  (shell-quote-argument (format ">%s<" needle-cdata))
                  files))))

(defun dix-existing-dixfiles (include-this &optional dir)
  "Get the set of existing files that match `dix-dixfiles' patterns.
Excludes the file of the current buffer unless INCLUDE-THIS is
non-nil.  The set is uniq'd and turned relative according to
DIR (defaults to `default-directory')."
  (let ((default-directory (or dir default-directory)))
    (let* ((this (buffer-file-name (current-buffer)))
           (existing (apply #'append (mapcar #'file-expand-wildcards dix-dixfiles)))
           (absolute (mapcar #'file-truename existing))
           (uniq (cl-remove-duplicates absolute :test #'equal))
           (w/o-this (if include-this uniq
                       (remove this uniq))))
      (mapcar #'file-relative-name w/o-this))))

(defvar dix-iso639-3-metacodes '(("nor" "nno" "nob") ("fit" "swe"))
  "Alist of metalanguages to individual languages.")

(defun dix-files-other-ext (ext &optional reverse)
  "Find the source file(s) with extension EXT corresponding to this file.
If REVERSE, find the file of the opposite direction of this
file's direction.  Returns a list, since metacodes and variants
means we can have multiple files per direction."
  (let* ((file (buffer-file-name))
         (dir (file-name-directory file))
         (base (file-name-base file))
         (butext (concat (file-name-as-directory dir) base "."))
         (prefix (and (string-match "\\(.*\\)[.]\\([^.-]+\\)-\\([^.-]+\\)[.]$"
                                    butext)
                      (match-string 1 butext)))
         (src (if reverse (match-string 3 butext) (match-string 2 butext)))
         (trg (if reverse (match-string 2 butext) (match-string 3 butext)))
         (metacodes (append
                     dix-iso639-3-metacodes
                     (dix-invert-alist dix-iso639-3-metacodes)))
         (with-metacodes (lambda (c) (or (assoc c metacodes)
                                    (list c)))))
    (dix-filter #'file-exists-p
                (apply #'append
                       (mapcar (lambda (cs)
                                 (mapcar (lambda (ct)
                                           (format "%s.%s-%s.%s" prefix cs ct ext))
                                         (funcall with-metacodes trg)))
                               (funcall with-metacodes src))))))

(defun dix--guess-bidix-mainpos-of-e ()
  "Find the first <s n=\"tag\"/> tag of <e> element at point.
Return nil on no match.
If no <s>, may try to guess from <par>."
  (save-excursion
    (dix-up-to "e" "section")
    (let ((end (save-excursion (nxml-forward-element) (point))))
      (when (or
             (save-excursion (re-search-forward "<s n=\"\\([^\"]*\\)" end 'noerror))
             (save-excursion (re-search-forward "<par n=\":?\\([^\"_]*\\)" end 'noerror)))
        (match-string-no-properties 1)))))

(defun dix-goto-lrx (&optional reverse)
  "Find the bidix word at point in the corresponding lrx-file.
On no match, insert a default rule for this pair.
Assumes we want the file where word would be the source language;
if REVERSE, treat the word as target instead."
  (interactive "P")
  (let* ((vr/vl (save-excursion (dix-up-to "e" "pardef")
                                (dix-get-vr-vl)))
         (tr (dix-l/r-at-point-reg))
         (tag (car tr))
         (lm-l (dix-l-word-at-point))
         (lm-r (dix-r-word-at-point))
         (w         (if (eq 'l tag) lm-l lm-r))
         (w-reverse (if (eq 'l tag) lm-r lm-l))
         (reverse (if (eq 'l tag) reverse (not reverse)))
         (s-tag (dix--guess-bidix-mainpos-of-e))
         (files0 (dix-files-other-ext "lrx" reverse))
         (files (or (and vr/vl       ; maybe filter file list by vr/vl
                         (eq tag (intern (car vr/vl)))
                         (seq-filter (lambda (file)
                                       (string-match-p (format ".*[.]%s-[^.]+[.]lrx"
                                                               (cdr vr/vl))
                                                       file))
                                     files0))
                    files0))
         (file (if (cdr files)
                   (dix--completing-read "File: " files nil t
                                         (if (cdr files) nil (car files)))
                 (car files))))
    ;; TODO: might also want to filter lists by those that have that lemma?
    (find-file file)
    (let ((p (save-excursion
               (goto-char (point-min))
               (search-forward (format "lemma=\"%s\"" w) nil 'noerror))))
      (if p
          (goto-char p)
        (widen)
        (goto-char (point-max))
        (nxml-backward-down-element 1)
        (when (equal "/lrx" (xmltok-start-tag-qname))
          ;; we want to be within /rules
          (nxml-backward-down-element 1))
        (insert (format
                 "  <rule><match lemma=\"%s\" tags=\"%s\"><select lemma=\"%s\"/></match></rule>\n"
                 w
                 (if s-tag (concat s-tag ".*") "*")
                 w-reverse))
        (message "Couldn't find a match; inserted default rule for %s→%s"
                 w
                 w-reverse)))))

(defun dix--match-data-highest-parens ()
  "Return the highest parenthesized expression of the previous search.
Usable as input to e.g. `replace-match' or `match-string' after a
`string-match'."
  (/ (- (length (match-data t)) 2) 2))

(defun dix--parallel-lang-modules (file)
  "Return an alist of files with the same path as FILE, except for language code."
  (when file
    (let* ((dir (file-name-directory file))
           (base (file-name-base file))
           (ext (file-name-extension file))
           (l-re "[a-z]\\{2,3\\}")
           (p-re (concat l-re "-" l-re))
           (re (format "/langs/\\(%s\\)/\\|/apertium-\\(%s\\)/\\|/apertium-\\(%s\\)/"
                       l-re l-re p-re))
           (m (string-match re dir)))
      (when m
        (let* ((num (dix--match-data-highest-parens))
               (beg (match-beginning num))
               (lang (match-string num dir))
               (glob (format "%s%s.%s"
                             (replace-match "*" t t dir num)
                             (replace-regexp-in-string (concat lang ".*") "*" base t t)
                             ext))
               (expanded (file-expand-wildcards glob))
               (key-re (format "/.*?\\(?:apertium-%s\\([.]%s\\)\\)?.*"
                               p-re p-re)))
          (mapcar (lambda (p)
                    (cons (replace-regexp-in-string key-re "\\1" (substring p beg))
                          p))
                  expanded))))))

(defun dix-other-language (language &optional possible-files)
  "Find the corresponding file in a different LANGUAGE.
If interactive or POSSIBLE-FILES is nil, fallback to
`dix--parallel-lang-modules'."
  (interactive (let ((possible (dix--parallel-lang-modules
                                (buffer-file-name))))
                 (list
                  (dix--completing-read "Language: "
                                        possible
                                        nil
                                        'require-match)
                  possible)))
  (let ((possible-files (or possible-files
                            (dix--parallel-lang-modules
                             (buffer-file-name)))))
    (if (and possible-files language)
        (find-file (cdr (assoc language possible-files)))
      (message "No matching other language/files"))))

;;;============================================================================
;;;
;;; Imenu
;;;

(defun dix-imenu-setup ()
  "Set up `imenu-generic-expression' for running `imenu'."
  (cond ((dix-is-transfer)
         (setq imenu-generic-expression
               '((nil "<def-macro\\s +n=\"\\([^\"]*\\)\"" 1)
                 (nil   "<rule\\s +comment=\"\\([^\"]*\\)\"" 1)
                 (nil   "<def-cat\\s +n=\"\\([^\"]*\\)\"" 1)
                 (nil   "<def-attr\\s +n=\"\\([^\"]*\\)\"" 1)
                 (nil   "<def-var\\s +n=\"\\([^\"]*\\)\"" 1)
                 (nil   "<def-list\\s +n=\"\\([^\"]*\\)\"" 1)
                 )))
        (t
         (setq imenu-generic-expression
               '((nil "<pardef\\s +n=\"\\([^\"]*\\)\"" 1)
                 (nil   "<sdef\\s +n=\"\\([^\"]*\\)\"" 1)
                 )))))


;;;============================================================================
;;;
;;; Advice
;;;

(advice-add #'fixup-whitespace
            :after
            (defun dix-fixup-whitespace ()
                "No whitespace between > and < in dix-mode.
Makes `join-line' do the right thing."
                (when (and dix-mode
                           (save-excursion (forward-char -1)
                                           (looking-at "\\s) \\s(")))
                  (delete-horizontal-space))))


;;;============================================================================
;;;
;;; Keybindings
;;;
(defun dix-C-c-letter-keybindings ()
  "Define keybindings with `C-c' followed by ordinary letters.
Not set by default, since such bindings should be reserved for
users."
  (define-key dix-mode-map (kbd "C-c L") #'dix-LR-restriction-copy)
  (define-key dix-mode-map (kbd "C-c R") #'dix-RL-restriction-copy)
  (define-key dix-mode-map (kbd "C-c s") #'dix-add-s)
  (define-key dix-mode-map (kbd "C-c p") #'dix-add-par)
  (define-key dix-mode-map (kbd "C-c C") #'dix-copy)
  (define-key dix-mode-map (kbd "C-c S") #'dix-sort-pardef)
  (define-key dix-mode-map (kbd "C-c G") #'dix-find-definition)
  (define-key dix-mode-map (kbd "C-c n") #'dix-goto-rule-number)
  (define-key dix-mode-map (kbd "C-c g") #'dix-guess-pardef)
  (define-key dix-mode-map (kbd "C-c x") #'dix-xmlise-using-above-elt)
  (define-key dix-mode-map (kbd "C-c V") #'dix-view-pardef)
  (define-key dix-mode-map (kbd "C-c W") #'dix-word-search-forward)
  (define-key dix-mode-map (kbd "C-c A") #'dix-grep-all)
  (define-key dix-mode-map (kbd "C-c D") #'dix-find-duplicate-pardefs))

(define-key dix-mode-map (kbd "C-c '") #'dix-guess-pardef)
(define-key dix-mode-map (kbd "C-c <C-tab>") #'dix-xmlise-using-above-elt)
(define-key dix-mode-map (kbd "C-c \\") #'dix-grep-all)
(define-key dix-mode-map (kbd "C-c SPC") #'dix-view-pardef)
(define-key dix-mode-map (kbd "C-c <") #'dix-add-s)
(define-key dix-mode-map (kbd "C-c .") #'dix-add-par)
(define-key dix-mode-map (kbd "C-c <left>") #'dix-LR-restriction-copy)
(define-key dix-mode-map (kbd "C-c <right>") #'dix-RL-restriction-copy)
(define-key dix-mode-map (kbd "C-c +") #'dix-copy)
(define-key dix-mode-map (kbd "C-c C-y") #'dix-copy-yank)
(define-key dix-mode-map (kbd "M-g o") #'dix-other-language)
(define-key dix-mode-map (kbd "M-g r") #'dix-goto-rule-number)
(define-key dix-mode-map (kbd "C-c M-.") #'dix-goto-lrx)
(define-key dix-mode-map (kbd "M-.") #'dix-find-definition)
(define-key dix-mode-map (kbd "M-,") #'pop-to-mark-command)

(define-prefix-command 'dix-replace-prefix)
(define-key dix-mode-map (kbd "C-c %") 'dix-replace-prefix)
(define-key dix-mode-map (kbd "C-c % RET") #'dix-replace-regexp-within-elt)
(define-key dix-mode-map (kbd "C-c % %") #'dix-replace-regexp-within-elt)
(define-key dix-mode-map (kbd "C-c % l") #'dix-replace-regexp-within-l)
(define-key dix-mode-map (kbd "C-c % r") #'dix-replace-regexp-within-r)

(define-key dix-mode-map (kbd "<C-tab>") #'dix-restriction-cycle)
(define-key dix-mode-map (kbd "<C-S-tab>") #'dix-v-cycle)
(define-key dix-mode-map (kbd "<S-iso-lefttab>") #'dix-v-cycle)
(define-key dix-mode-map (kbd "M-n") #'dix-next)
(define-key dix-mode-map (kbd "M-p") #'dix-previous)
(define-key dix-mode-map (kbd "M-N") #'dix-find-next-file)
(define-key dix-mode-map (kbd "M-P") #'dix-find-previous-file)
(define-key dix-mode-map (kbd "<SPC>") #'dix-insert-space)
(define-key dix-mode-map (kbd "<backspace>") #'dix-backspace)
(define-key dix-mode-map (kbd "C-<") #'dix-<)
(define-key dix-mode-map (kbd "C->") #'dix->)
(define-key dix-mode-map (kbd "C-x n s") #'dix-narrow-to-sdef)

;;;============================================================================
;;;
;;; Run hooks
;;;
(run-hooks 'dix-load-hook)

(provide 'dix)

;;;============================================================================

;;; dix.el ends here
