;;; magik-session.el --- mode for running a Smallworld Magik interactive process

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;;
;;; The filter for the magik shell process is in magik-session-filter.el
;;
;; This is a new version of the gis-mode that uses a vector of marker
;; pairs rather than a list.  This allows us to move up and down the
;; array efficiently and also use things like binary search.
;;
;; Every hundred commands, a new bigger vector is created and the
;; invalid or degenerate previous commands are cleaned out - previous
;; commands are counted as degenerate if they point at a non-existent
;; buffer (cos the user killed the buffer and created a new one) or
;; have length zero (cos the user deleted the text the the markers
;; bounded).
;;
;; Unlike previous versions, the markers will mark the whole of the
;; text sent to the gis, including the dollar and the return.
;;
;; Note that all previous commands need to be kept, not just the last
;; 20 or so because the markers are the only way we can know what the
;; commands were - looking for prompts and dollars is too unreliable.
;;
;; The previous commands are kept in a buffer local variable called
;; magik-session-prev-cmds.
;;
;; Where possible, we try to allow more than one Magik process to be running.
;; This gets a bit tricky for things like transmit-method-to-magik
;; because they have to know where to send the magik to.  In order to
;; simplify this, we are getting rid of the variable,
;; magik-process-name, because it is a duplicate of magik-session-buffer.  We
;; also don't ever refer to the process by its name but always by its
;; buffer - this should save any confusion with Magik process naming.
;;
;; We don't rely on the form of the prompt any more.  We just rely on
;; it ending in a space.  The only place where we need to be sure is in
;; the filter.
;;
;; In this version of magik-session-mode, we don't have any automatic
;; indentation of magik-code.  The tab is just for inserting tabs and
;; nothing else.
;;
;; During a sequence of M-p and M-n commands, the actual command
;; we're looking at is recorded in the buffer-local variable,
;; magik-session-cmd-num.
;;
;; Unlike direct-gis-mode.el we keep the oldest command at the front.
;; This is fine because we can get to the end of a vector quickly.
;; We record how many commands are in our vector in the buffer-local
;; Command history is stored in a ring (ring.el).  Previous commands
;; in the buffer are located by searching backward for the prompt
;; regexp (`magik-session-prompt').

;;; Code:

(eval-when-compile
  (require 'comint)
  (defvar comint-last-input-start)
  (defvar comint-last-input-end)
  (defvar msb-menu-cond))

(require 'yasnippet)
(require 'magik-mode)
(require 'magik-indent)
(require 'magik-pragma)

(defgroup magik-session nil
  "Customise Magik session group."
  :group 'magik)

(defcustom magik-session-buffer nil
  "*The default Smallworld session.
Used for switching to the first Smallworld session."
  :group 'magik-session
  :type '(choice string (const nil)))

(defcustom magik-session-buffer-default-name "magik"
  "*The default name of a Magik session buffer when creating new Magik sessions."
  :group 'magik-session
  :type 'string)

(defcustom magik-session-prompt (regexp-opt `("Magik> " "MagikSF> " "Majestik> "))
  "String or Regular expression identifying the default Magik Prompt.
If global value is nil, a Magik session will attempt to discover the current
setting of the Magik Prompt by calling `magik-session-prompt-get'."
  :group 'magik-session
  :type '(choice regexp (const nil)))

(defcustom magik-session-command-history-max-length 90
  "*The maximum length of the displayed `magik-session-command' in the submenu.
This applies to the Magik Session -> Magik Session Command History submenu.
`magik-session-command' is a string of the form \"[DIRECTORY] COMMAND ARGS\"."
  :group 'magik-session
  :type  'integer)

(defcustom magik-session-command-history-max-length-dir (floor (/ magik-session-command-history-max-length 2))
  "*The maximum length of the displayed directory path in the submenu.
This applies to the Magik Session -> Magik Session Command History submenu."
  :group 'magik-session
  :type  'integer)

(defcustom magik-session-recall-cmd-move-to-end nil
  "*If t, move the cursor point to the end of the recalled command.
This behaviour is available for \\[magik-session-recall-prev-cmd] and \\[magik-session-recall-next-cmd] only.
The default is nil, which preserves the original behaviour to leave
the cursor point in the same position.

The similar commands, \\[magik-session-recall-prev-matching-cmd] and \\[magik-session-recall-next-matching-cmd]
that use command string matching are not affected by this setting."
  :group 'magik-session
  :type 'boolean)

(defgroup magik-session-faces nil
  "Faces for displaying text in the Magik session."
  :group 'magik-session)

(defface magik-session-error-face
  '((t :inherit magik-warning-face))
  "Font Lock mode face used to display Error lines."
  :group 'magik-session-faces)

(defface magik-session-prompt-face
  '((t :inherit magik-class-face))
  "Font Lock mode face used to display the Magik Prompt."
  :group 'magik-session-faces)

(defface magik-session-reference-face
  '((t :inherit magik-global-reference-face))
  "Font Lock mode face used to display global references."
  :group 'magik-session-faces)

(defface magik-session-traceback-face
  '((t :inherit magik-warning-face))
  "Font Lock mode face used to display Traceback lines."
  :group 'magik-session-faces)

(defface magik-session-warning-face
  '((t :inherit magik-warning-face))
  "Font Lock mode face used to display Warning lines."
  :group 'magik-session-faces)

(defcustom magik-session-strict-line-start t
  "If non-nil, force matching of session output at the beginning of the line.
If nil, allow matching anywhere in the line."
  :group 'magik-session
  :type 'boolean)

(defcustom magik-session-font-lock-keywords
  (append
   magik-font-lock-keywords-1
   magik-font-lock-keywords-2
   (let ((prefix (if magik-session-strict-line-start "^" "")))
     (list
      `(,(concat prefix "\\*\\*\\*\\* Error.*$")          0 'magik-session-error-face t)
      `(,(concat prefix "\\*\\*\\*\\* Warning.*$")        0 'magik-session-warning-face t)
      `(,(concat prefix "\\*\\*\\*\\* Parser warning.*$") 0 'magik-session-warning-face t)
      '("^---- traceback.* ----" . 'magik-session-traceback-face)
      '("^@.*$"                   . 'magik-session-reference-face))))
  "Additional expressions to highlight in Magik mode."
  :group 'magik-session
  :type 'sexp)

(defcustom magik-session-start-process-pre-hook nil
  "*Hook run before starting the process."
  :group 'magik-session
  :type 'hook)

(defcustom magik-session-start-process-post-hook nil
  "*Hook run after starting the process."
  :group 'magik-session
  :type 'hook)

(defcustom magik-session-kill-process-pre-hook nil
  "*Hook run before killing the process."
  :group 'magik-session
  :type 'hook)

(defcustom magik-session-kill-process-post-hook nil
  "*Hook run after killing the process."
  :group 'magik-session
  :type 'hook)

(defcustom magik-session-set-priority-post-hook nil
  "*Hook run after changing the magik session priority."
  :group 'magik-session
  :type 'hook)

(defcustom magik-session-auto-insert-dollar nil
  "If t, automatically insert a $ after each valid Magik statement."
  :group 'magik-session
  :type 'boolean)

(defcustom magik-session-sentinel-hooks nil
  "*Hooks to run after the Magik process has finished.
Each hook is passed the exit status of the Magik process."
  :group 'magik-session
  :type 'hook)

(defcustom magik-session-drag-n-drop-mode nil
  "Variable storing setting of \\[magik-session-drag-n-drop-mode]."
  ;;Use of integers is a standard way of forcing minor modes on and off.
  :group 'magik-session
  :type '(choice (const :tag "On" 1)
                 (const :tag "Off" -1)))

(defvar magik-session-buffer-alist nil
  "Alist storing Magik session buffer name and number.
Used for prefix key switching.")

(defvar magik-session-drag-n-drop-mode-line-string nil
  "Mode-line string to use for Drag and Drop mode.")

(defvar magik-session-filter-state nil
  "State variable for the filter function.")

(defvar magik-session-process nil
  "The process object of the command running in the buffer.")

(defvar magik-session-current-command nil
  "The current `magik-session-command' in the current buffer.")

(defvar-local magik-session-exec-path nil
  "Stored value of variable `exec-path'.
It holds the value from when the Magik session process was started.")

(defvar-local magik-session-process-environment nil
  "Stored value of variable `process-environment'.
It holds the value from when the Magik session process was started.")

(defvar magik-session-cb-buffer nil
  "The Class browser buffer associated with the Magik session process.")

(defvar magik-session-history-length 20
  "The default number of commands to fold.")

(require 'ring)

(defvar-local magik-session-history-ring nil
  "Ring of previous command strings for the session.")
(put 'magik-session-history-ring 'permanent-local t)

(defvar-local magik-session-history-index nil
  "Current index into `magik-session-history-ring' during recall.
nil means not currently navigating history.")

(defcustom magik-session-history-ring-size 200
  "Maximum number of commands to keep in the session history ring."
  :type 'integer
  :group 'magik-session)

(defvar magik-session-command-syntax-table
  (let ((tbl (make-syntax-table)))
    ;; Allow embedded environment variables in Windows %% and Unix $ or ${} formats
    (modify-syntax-entry ?$  "w"  tbl)
    (modify-syntax-entry ?\{ "w"  tbl)
    (modify-syntax-entry ?\} "w"  tbl)
    (modify-syntax-entry ?%  "w"  tbl)
    ;; make _ a word character for environment variable substitution
    (modify-syntax-entry ?_  "w"  tbl)
    ;; count single and double quotes as a true quote
    (modify-syntax-entry ?\' "\"" tbl)
    (modify-syntax-entry ?\" "\"" tbl)
    ;; allow \ as an escape character
    (modify-syntax-entry ?\\ "\\" tbl)
    ;; treat . as a word character (for filenames)
    (modify-syntax-entry ?.  "w"  tbl)
    ;; Special characters for Windows filenames (mainly for NT 8.3 names)
    (modify-syntax-entry ?:  "w"  tbl)
    (modify-syntax-entry ?~  "w"  tbl)
    tbl)
  "Syntax table in use for parsing quotes in magik-session-command.")

;; Create the syntax table
(unless magik-session-command-syntax-table
  (setq magik-session-command-syntax-table (make-syntax-table))
  ;; Allow embedded environment variables in Windows %% and Unix $ or ${} formats
  (modify-syntax-entry ?$  "w"  magik-session-command-syntax-table)
  (modify-syntax-entry ?\{ "w"  magik-session-command-syntax-table)
  (modify-syntax-entry ?\} "w"  magik-session-command-syntax-table)
  (modify-syntax-entry ?%  "w"  magik-session-command-syntax-table)

  (modify-syntax-entry ?_  "w"  magik-session-command-syntax-table) ;make _ a word character for environment variable substitution

  (modify-syntax-entry ?\' "\"" magik-session-command-syntax-table) ;count single quotes as a true quote
  (modify-syntax-entry ?\" "\"" magik-session-command-syntax-table) ;count double quotes as a true quote
  (modify-syntax-entry ?\\ "\\" magik-session-command-syntax-table) ;allow a \ as an escape character
  (modify-syntax-entry ?.  "w"  magik-session-command-syntax-table) ;(for filenames)

  ;; Special characters for Windows filenames
  (modify-syntax-entry ?:  "w"  magik-session-command-syntax-table)
  (modify-syntax-entry ?~  "w"  magik-session-command-syntax-table) ;(mainly for NT 8.3 filenames)
  )

(defcustom magik-session-command-default "[%HOME%] %SMALLWORLD_GIS%/bin/x86/runalias.exe swaf_mega"
  "The default value for magik-session-command.
It illustrates how Environment variables can be embedded in the command.
Also it neatly shows the three ways of referencing Environment variables,
via the Windows and Unix forms: %%, $ and ${}.  All of which are
expanded irrespective of the current Operating System."
  :group 'magik-session
  :type 'string)

;;Although still settable by the user via M-x set-variable,
;;it is preferred that magik-session-comand-history be used instead.
(defvar magik-session-command magik-session-command-default
  "*The command used to invoke the gis.
It is offered as the default string for next time.")

(defcustom magik-session-command-history nil
  "*List of commands run by a Magik buffer."
  :group 'magik-session
  :type  '(choice (const nil)
                  (repeat string)))
(put 'magik-session-command-history 'permanent-local t)

(defun magik-session-customize ()
  "Open Customization buffer for Magik Session Mode."
  (interactive)
  (customize-group 'magik-session))

(defun magik-session-prompt-update-font-lock ()
  "Update the Font-lock variable `magik-session-font-lock-keywords'.
Uses current `magik-session-prompt' setting as value."
  (let ((entry (list (concat "^" magik-session-prompt) 0 ''magik-session-prompt-face t)))
    (unless (member entry magik-session-font-lock-keywords)
      (add-to-list 'magik-session-font-lock-keywords entry)
      (font-lock-refresh-defaults))))

(defun magik-session-prompt-get (&optional force-query-p)
  "If `magik-session-prompt' is nil, get the Magik session's command line prompt.
If interactive and a prefix arg is used then Magik session will be
queried irrespective of default value of `magik-session-prompt'"
  (interactive "P")
  (if (and (null force-query-p)
           (stringp (default-value 'magik-session-prompt))) ;user has overridden setting
      (progn
        (compat-call setq-local magik-session-prompt (or magik-session-prompt ;user may have set a local value for it
                                                         (default-value 'magik-session-prompt)))
        (magik-session-prompt-update-font-lock))
    (process-send-string
     magik-session-process
     "_block
  !terminal!.put(%x.from_value(1))
  !terminal!.put(%P)
  _if magik_rep.responds_to?(:prompt_generator)
  _then !terminal!.write(magik_rep.prompt_generator.invoke(\"MagikSF> \"))
  _else !terminal!.write(\"Magik\\(SF\\|2\\)> \")
  _endif
  !terminal!.put(%x.from_value(5))
  !terminal!.put(%space)
    _endblock\n$\n")))
(add-hook 'magik-session-start-process-post-hook 'magik-session-prompt-get)

(defun magik-session-shell ()
  "Start a command shell with the same environment as the current Magik process."
  (interactive)
  (require 'shell)
  (let ((buffer (concat "*shell*" (buffer-name)))
        (version (and (boundp 'magik-version-current)
                      (symbol-value 'magik-version-current)))
        (smallworld-gis magik-smallworld-gis))
    (if (eq system-type 'windows-nt)
        (make-comint-in-buffer "magik-session-shell"
                               buffer
                               (executable-find "cmd") nil "/k"
                               (expand-file-name "environment.bat" (file-name-concat smallworld-gis "config")))
      (make-comint-in-buffer "magik-session-shell"
                             buffer
                             shell-file-name nil "-i"))
    (with-current-buffer buffer
      (when (stringp version)
        (set 'magik-version-current version))
      (set 'magik-smallworld-gis smallworld-gis))
    (display-buffer buffer)))

(defun magik-session-parse-gis-command (command)
  "Parse the magik-session-command string taking care of any quoting.
Return a list of all the components of the COMMAND."

  ;;Copy the string into a temp buffer.
  ;;Use the Emacs sexp code and an appropriate syntax-table 'magik-session-command-syntax-table'
  ;;to cope with quotes and possible escaped quotes.
  ;;forward-sexp therefore guarantees preservation of white within quoted regions.
  ;;However, I do some extra work to try and remove the surrounding quotes from the returned result
  (let ((temp-buf (get-buffer-create " *magik-session-command parser*"))
        (command-list))
    (save-excursion
      (save-match-data
        (set-buffer temp-buf)
        (erase-buffer)
        (set-syntax-table magik-session-command-syntax-table)
        (insert command)

                                        ;Remove excess trailing whitespace to avoid spurious extra empty arguments being passed
        (goto-char (point-max))
        (delete-horizontal-space)

        (goto-char (point-min))
        (condition-case var
            (setq command-list
                  (cl-loop
                   with start-char ;point containing valid word character - not whitespace or a quote
                   with substr ;substring containing command-line argument
                   do (progn
                        (setq start-char
                              (save-excursion
                                (skip-chars-forward " \t") ;skip intervening white space
                                (and (looking-at "[\"\']") (forward-char 1)) ;strip begin-quote
                                (point)))

                        (forward-sexp)
                        (setq substr (buffer-substring start-char (point)))
                        (when (string-match "[\"\']$" substr) ;strip end-quote if any
                          (setq substr (substring substr 0 (match-beginning 0))))
                                        ;Now look for embedded environment variables
                        (setq substr (substitute-in-file-name substr)))
                   collect substr
                   until (eobp)))
          (scan-error
           (error "%s or quotes" (cadr var)))))
      (kill-buffer temp-buf)
      command-list)))

(defun magik-session-buffer-alist-remove ()
  "Remove current buffer from `magik-session-buffer-alist'."
  (let ((c (rassoc (buffer-name) magik-session-buffer-alist)))
    (when c
      (setcdr c nil)
      (car c))))

(defun magik-session-buffer-alist-prefix-function (arg mode predicate)
  "Function to process prefix keys when used with \\[magik-session]."
  (let ((buf (cdr (assq arg magik-session-buffer-alist))))
    (if (and buf
             (with-current-buffer buf
               (magik-utils-buffer-mode-list-predicate-p predicate)))
        t
      (error "No Magik session buffer"))
    buf))

(defun magik-session-buffer-alist-sorted ()
  "Return a copy of `magik-session-buffer-alist' sorted by session number."
  (sort (copy-alist magik-session-buffer-alist)
        #'(lambda (a b) (< (car a) (car b)))))

(defun magik-session-set-priority (buffer priority)
  "Renumber Magik session BUFFER to PRIORITY in `magik-session-buffer-alist'.
Lower numbers sort first in the Tools -> Magik menu, are reached with
\\[magik-session] and a matching numeric prefix arg, and are preferred by
`magik-completion' when picking which live session to query.  If another
session already holds PRIORITY, the two swap numbers."
  (interactive
   (list (completing-read "Magik session buffer: "
                          (magik-utils-buffer-mode-list 'magik-session-mode)
                          nil t nil nil (buffer-name))
         (read-number "New priority (1 = highest): " 1)))
  (let ((entry (rassoc buffer magik-session-buffer-alist))
        (other (assq priority magik-session-buffer-alist)))
    (unless entry
      (error "%s is not a registered Magik session buffer" buffer))
    (let ((old-priority (car entry)))
      (setcar entry priority)
      (when (and other (not (eq other entry)))
        (setcar other old-priority)))
    (message "%s is now Magik session %d" buffer priority))
  (run-hooks 'magik-session-set-priority-post-hook))

(defun magik-session-command-display (command)
  "Return shortened Magik session COMMAND suitable for display."
  (when (stringp command) ; defensive programming. Should be a string but need to avoid errors
    (let              ; because this function is called in a menu-update-hook
        ((command-len (- (min (length command) magik-session-command-history-max-length)))
         (label ""))
      (save-match-data
        (when (string-match "^\\[[^\]]*\\]" command)
          (setq label
                (concat (magik-utils-file-name-display (match-string 0 command)
                                                       magik-session-command-history-max-length-dir)
                        "..."))))
      (concat label (substring command (+ command-len (length label)))))))

(defun magik-session-update-tools-magik-gis-menu ()
  "Update Magik Session processes submenu in Tools -> Magik pulldown menu."
  (let* ((magik-session-alist (magik-session-buffer-alist-sorted))
         magik-session-list)
    (dolist (c magik-session-alist)
      (let ((i   (car c))
            (buf (cdr c)))
        (when buf
          (setq magik-session-list
                (append magik-session-list
                        (list (vector buf
                                      (list 'display-buffer buf)
                                      ':active t
                                      ':keys (format "M-%d f2 z" i))))))))
    ;;Magik session buffers ordered according to when they were started.
    ;;killed session numbers are reused.
    (easy-menu-change (list "Tools" "Magik")
                      "Magik Session Processes"
                      (or magik-session-list (list "No Processes")))))

(defun magik-session-update-magik-session-menu ()
  "Update the Magik Session Command history in the Magik Session pulldown menu."
  (when (derived-mode-p 'magik-session-mode)
    (let (command-list)
      (save-match-data
        ;;Delete duplicates from magik-session-command-history local and global values
        ;;Note: delete-duplicates does not appear to work on localised variables.
        (compat-call setq-local magik-session-command-history (cl-remove-duplicates magik-session-command-history :test #'equal))
        (setq-default magik-session-command-history
                      (cl-remove-duplicates (default-value 'magik-session-command-history)
                                            :test #'equal))

        (dolist (command magik-session-command-history)
          (push (apply
                 'vector
                 (magik-session-command-display command)
                 (list 'gis (buffer-name) (purecopy command))
                 ':active
                 '(not (get-buffer-process (buffer-name)))
                 ;; ':key-sequence nil
                 (list ':help (purecopy command)))
                command-list)))

      (when (get-buffer-process (buffer-name))
        (setq command-list
              (append command-list
                      (list "---"
                            (apply 'vector (magik-session-command-display magik-session-current-command)
                                   'ignore ':active nil (list ':key-sequence nil
                                                              ':help (purecopy magik-session-current-command)))
                            (apply 'vector "Start New Magik Session" 'magik-session-new-buffer
                                   ':active t
                                   ':keys '("C-u f2 z"))))))

      (easy-menu-change (list "Magik Session")
                        "Magik Session Command History"
                        (or command-list (list "No History"))))))

(defun magik-session-update-tools-magik-shell-menu ()
  "Update External Shell Processes submenu in Tools -> Magik pulldown menu."
  (let ((shell-bufs (magik-utils-buffer-mode-list 'shell-mode
                                                  (lambda () (symbol-value 'magik-smallworld-gis))))
        shell-list)
    (cl-loop for buf in shell-bufs
             do (push (vector buf (list 'display-buffer buf) t) shell-list))
    (easy-menu-change (list "Tools" "Magik")
                      "External Shell Processes"
                      (or shell-list (list "No Processes")))))

(define-derived-mode magik-session-mode nil "Magik Session"
  "Major mode to run a Magik session as a direct subprocess.
The default name for a buffer running a session is \"*magik*\". The name of
the current session buffer is stored in the user option `magik-session-buffer`.
There are many ways to recall previous commands (see the online
help with \\[help-command]).
Commands are sent to the session with the \\[magik-session-newline] or
\\[magik-session-send-command-at-point].
Entry to this mode runs `magik-session-mode-hook`.
\\{magik-session-mode-map}"
  :group 'magik-session
  :syntax-table magik-base-mode-syntax-table

  (compat-call setq-local
               selective-display t
               comint-last-input-start (make-marker)
               comint-last-input-end (make-marker)
               magik-session-command-history (or magik-session-command-history
                                                 (default-value 'magik-session-command-history))
               magik-session-filter-state "\C-a"
               magik-session-cb-buffer (concat "*cb*" (buffer-name))
               magik-session-drag-n-drop-mode-line-string " DnD"
               magik-transmit-debug-mode-line-string " #DEBUG"
               show-trailing-whitespace nil
               font-lock-defaults '(magik-session-font-lock-keywords nil t ((?_ . "w")))
               mode-line-process '(": %s")
               local-abbrev-table magik-base-mode-abbrev-table)

  (unless magik-session-history-ring
    (setq magik-session-history-ring (make-ring magik-session-history-ring-size)))

  (unless (and magik-session-buffer (get-buffer magik-session-buffer))
    (setq-default magik-session-buffer (buffer-name)))

  (unless (rassoc (buffer-name) magik-session-buffer-alist)
    (let ((n 1))
      (while (cdr (assq n magik-session-buffer-alist))
        (setq n (1+ n)))
      (if (assq n magik-session-buffer-alist)
          (setcdr (assq n magik-session-buffer-alist) (buffer-name))
        (add-to-list 'magik-session-buffer-alist (cons n (buffer-name))))))

  (abbrev-mode 1)

  (with-current-buffer (get-buffer-create (concat " *filter*" (buffer-name)))
    (erase-buffer))

  (add-hook 'before-change-functions #'magik-session--prepare-for-edit-cmd nil t)
  (add-hook 'menu-bar-update-hook #'magik-session-update-magik-session-menu nil t)
  (add-hook 'menu-bar-update-hook #'magik-session-update-tools-magik-gis-menu nil t)
  (add-hook 'menu-bar-update-hook #'magik-session-update-tools-magik-shell-menu nil t)
  (add-hook 'kill-buffer-hook #'magik-session-buffer-alist-remove nil t))

(defvar magik-session-menu nil
  "Keymap for the Magik session buffer menu bar.")

(easy-menu-define magik-session-menu magik-session-mode-map
  "Menu for Magik session mode."
  `(,"Magik Session"
    [,"Previous Command"                 magik-session-recall-prev-cmd           t]
    [,"Next Command"                     magik-session-recall-next-cmd           t]
    [,"Previous Matching Command"        magik-session-recall-prev-matching-cmd  t]
    [,"Next Matching Command"            magik-session-recall-next-matching-cmd  t]
    "----"
    [,"Fold"                             magik-session-display-history   :active t :keys "C-c C-p"]
    [,"Unfold"                           magik-session-undisplay-history :active t :keys "C-c C-n"]
    "----"
    [,"Electric Template"                magik-explicit-electric-space           t]
    ;; [,"Deep Print"                       magik-deep-print                      :active t :keys "<f2> x"]
    "----"
    [,"Previous Traceback"               magik-session-traceback-up              t]
    [,"Next Traceback"                   magik-session-traceback-down            t]
    [,"Print Traceback"                  magik-session-traceback-print   :active t :keys "C-c C-t"]
    [,"Save Traceback"                   magik-session-traceback-save            t]
    "----"
    [,"External Shell Process"           magik-session-shell                     t]
    [,"Kill Magik Process"               magik-session-kill-process              (and magik-session-process
                                                                                      (eq (process-status magik-session-process) 'run))]
    [,"Set Session Priority..."          magik-session-set-priority              t]
    (,"Magik Session Command History")
    "---"
    (,"Toggle..."
     [,"Magik Session Filter"             magik-session-filter-toggle-filter     :active t
      :style toggle :selected (let ((b (get-buffer-process
                                        (current-buffer))))
                                (and b (process-filter b)))]
     [,"Drag and Drop"                  magik-session-drag-n-drop-mode       :active t
      :style toggle :selected magik-session-drag-n-drop-mode])
    [,"Customize"                       magik-session-customize               t]))

(defun magik-session-sentinel (proc msg)
  "Sentinel function, runs when the magik process exits."
  (let ((magik-session-exit-status (process-exit-status proc))
        (buf (process-buffer proc)))
    (with-current-buffer buf
      ;; ensure process end message is at end of buffer.
      (goto-char (point-max))
      (cond ((eq (process-status proc) 'exit)
             (insert "\n\n" (format "Process %s %s"
                                    (process-name proc)
                                    msg)
                     "\n")
             (message "Magik process %s exited: %s" buf msg))
            ((eq (process-status proc) 'signal)
             (insert "\n\n" (format "Process %s %s"
                                    (process-name proc)
                                    msg)
                     "\n")
             (message "Magik process %s signalled: %s" buf msg)))

      (message "Magik process %s process %s has terminated with exit code: %s"
               buf (process-name proc) (number-to-string magik-session-exit-status))

      ;;Allow messages to appear in *Messages* buffer
      (sit-for 0.01)
      (run-hook-with-args 'magik-session-sentinel-hooks magik-session-exit-status))))

(defun magik-session-start-process (args)
  "Run a Magik process in the current buffer.
Adds `magik-session-current-command' to `magik-session-command-history'
if not already there."
  (run-hooks 'magik-session-start-process-pre-hook)
  (or (member magik-session-current-command magik-session-command-history)
      (add-to-list 'magik-session-command-history magik-session-current-command))
  (compat-call setq-local magik-session-process (apply 'start-process "magik-session-process" (current-buffer) (car args) (cdr args)))
  (set-process-sentinel magik-session-process 'magik-session-sentinel)
  (set-marker (process-mark magik-session-process) (point-max))
  (set-process-filter magik-session-process 'magik-session-filter)

  ;;MF New bit for connecting to the method finder:
  ;;MF We nuke the current cb first and reconnect later.
  (when (and magik-cb-dynamic (get-buffer magik-session-cb-buffer))
    (let ((magik-cb-process (get-buffer-process magik-session-cb-buffer)))
      (when magik-cb-process
        (delete-process magik-cb-process)))
    (process-send-string magik-session-process "_if method_finder _isnt _unset\n_then\n  method_finder.lazy_start?\n  method_finder.send_socket_to_emacs()\n_endif\n$\n"))
  (sit-for 0.01)
  (run-hooks 'magik-session-start-process-post-hook))

;; Put up here coz of load order problems.
;; The logic of the `F2 s' is still not quite right anyway.

(defun magik-session--expand-aliases (command prompt-p default-dir history)
  "Iteratively expand csh-style aliases referenced in COMMAND.
If PROMPT-P, prompt the user once per expansion step with HISTORY as the
prior-command list (passed to `read-string').  DEFAULT-DIR is prepended
to COMMAND when it lacks a `[dir]' prefix.  Strings of the form [rev19] or
[rev20] are silently removed.  Returns the fully expanded command string."
  (let ((alias-buffer "*temp gis alias buffer*")
        ;; read-string's history arg does not work with buffer-local variables
        (command-history history)
        (keepgoing t)
        (rev-1920-regexp " +\\[rev\\(19\\|20\\)\\] +")
        (alias-subst-regexp "\\\\!\\(\\\\\\)?\\*")
        alias-beg alias-expansion dir cmd args)
    (unwind-protect
        (with-current-buffer (get-buffer-create alias-buffer)
          (erase-buffer)
          (when (and (string-equal shell-file-name "/bin/csh")
                     (file-readable-p "~/.alias"))
            (insert-file-contents "~/.alias"))
          (while keepgoing
            (setq keepgoing nil)
            (setq command (sub command rev-1920-regexp " "))
            (or (eq (string-match "\\[" command) 0)
                (setq command (concat "[" default-dir "] " command)))
            (when prompt-p
              (setq command (read-string "Magik command: "
                                         (car command-history)
                                         'command-history)))
            (when (string-match rev-1920-regexp command)
              (setq keepgoing t
                    command (sub command rev-1920-regexp " ")))
            (or (eq (string-match "\\[" command) 0)
                (setq command (concat "[" default-dir "] " command)))
            (string-match "\\[\\([^\]]*\\)\\] *\\([^ ]*\\) *\\(.*\\)" command)
            (setq dir  (substring command (match-beginning 1) (match-end 1))
                  cmd  (substring command (match-beginning 2) (match-end 2))
                  args (substring command (match-beginning 3) (match-end 3)))
            (goto-char (point-min))
            (when (re-search-forward (concat "^alias[ \t]+" (regexp-quote cmd) "[ \t]+") nil t)
              (setq keepgoing t
                    alias-beg (match-end 0))
              (goto-char alias-beg)
              (if (looking-at "['\"]")
                  (progn
                    (cl-incf alias-beg)
                    (end-of-line)
                    (re-search-backward "['\"]"))
                (end-of-line))
              (setq alias-expansion (buffer-substring alias-beg (point)))
              (or (string-match alias-subst-regexp alias-expansion)
                  (setq alias-expansion (concat alias-expansion " \\!*")))
              (setq alias-expansion (sub alias-expansion alias-subst-regexp args)
                    command (concat "[" dir "] " alias-expansion)))))
      (when (get-buffer "*temp gis alias buffer*")
        (kill-buffer "*temp gis alias buffer*")))
    command))

;;;###autoload
(defun magik-session (&optional buffer command)
  "Run a Magik process in a buffer in `magik-session-mode'.

The command is typically \"runalias\" or \"gis\", but
can be any interactive program such as \"csh\".

The program that is offered as a default is stored in the variable,
`magik-session-command', which you can customise.  e.g.

\(setopt magik-session-command
\"[$HOME] runalias swaf_mega\"
\)
The command automatically expands environment variables using
Windows %% and Unix $ and ${} nomenclature.

You can setup a list of standard commands by setting the
default value of `magik-session-command-history'.

Prefix argument controls:
With a numeric prefix arg, switch to the Magik process of that number
where the number indicates the order it was started. The
SW->Magik Processes indicates which numbers are in use. If a Magik process
buffer is killed, its number is reused when a new Magik process is started.

With a non-numeric prefix arg, ask user for buffer name to use for
the process.  This will default to a unique currently unused name based upon
the current value of `magik-session-buffer-default-name'.

If there is already a Magik process running in a visible window or
frame, just switch to that buffer, or prompt if more than one.  If
there is not, prompt for a command to run, and then run it."

  (interactive)
  (when command
    (setq magik-session-command command))
  (let (dir
        cmd
        args
        (magik-session-start-process-pre-hook magik-session-start-process-pre-hook)
        (buffer (or
                 (magik-utils-get-buffer-mode (cond (buffer buffer)
                                                    ((derived-mode-p 'magik-session-mode) (buffer-name))
                                                    (t nil))
                                              'magik-session-mode
                                              "Enter Magik Session buffer:"
                                              (or magik-session-buffer magik-session-buffer-default-name)
                                              'magik-session-buffer-alist-prefix-function
                                              (generate-new-buffer-name magik-session-buffer-default-name)
                                              t)
                 (generate-new-buffer-name (or magik-session-buffer magik-session-buffer-default-name))))
        (rev-1920-regexp " +\\[rev\\(19\\|20\\)\\] +")
        (alias-subst-regexp "\\\\!\\(\\\\\\)?\\*"))
    (if (and (get-buffer-process buffer)
             (eq (process-status (get-buffer-process buffer)) 'run))
        (progn
          (pop-to-buffer buffer)
          (goto-char (point-max)))

      ;; Else start a fresh gis.  Each round through `--expand-aliases'
      ;; lets the user edit the expanded alias; we loop until no further
      ;; alias expansion is found.
      (setq magik-session-command
            (magik-session--expand-aliases magik-session-command
                                           (null command)
                                           default-directory
                                           magik-session-command-history))
      (string-match "\\[\\([^\]]*\\)\\] *\\([^ ]*\\) *\\(.*\\)" magik-session-command)
      (setq dir  (substring magik-session-command (match-beginning 1) (match-end 1))
            cmd  (substring magik-session-command (match-beginning 2) (match-end 2))
            args (substring magik-session-command (match-beginning 3) (match-end 3)))

      (pop-to-buffer (get-buffer-create buffer))
      (unless (derived-mode-p 'magik-session-mode)
        (magik-session-mode))
      (goto-char (point-max))
      (setq default-directory (expand-file-name
                               (file-name-as-directory
                                (magik-utils-substitute-in-file-name dir))))
      (compat-call setq-local
                   magik-smallworld-gis (or magik-smallworld-gis
                                            (when (boundp 'magik-smallworld-gis-current)
                                              (symbol-value 'magik-smallworld-gis-current)))
                   magik-session-current-command (copy-sequence magik-session-command)
                   magik-session-command-history (cons magik-session-current-command
                                                       (delete magik-session-current-command magik-session-command-history)))
      (setq-default magik-session-command-history (cons magik-session-current-command
                                                        (delete magik-session-current-command magik-session-command-history)))
      (or (file-directory-p default-directory)
          (error "Directory does not exist: %s" default-directory))

      (insert (format "Startup time: %s\nCommand: %s\n" (current-time-string) magik-session-command))

      (magik-session-start-process (magik-session-parse-gis-command (concat (magik-utils-substitute-in-file-name cmd) " " args))))))

(defun magik-session-new-buffer ()
  "Start a new Magik session."
  (interactive)
  (magik-session (generate-new-buffer-name
                  (or magik-session-buffer magik-session-buffer-default-name))))

(defun magik-session-kill-process ()
  "Kill the current Magik process."
  (interactive)
  (run-hooks 'magik-session-kill-process-pre-hook)
  (when (and magik-session-process
             (eq (process-status magik-session-process) 'run)
             (y-or-n-p "Kill the Magik process? "))
    (let ((status (process-status magik-session-process)))
      (kill-process magik-session-process)
      (sit-for 0.1)
      (when (eq status (process-status magik-session-process))
        (insert "\nMagik is still busy and will exit at an appropriate point. Please be patient... \n"))
      (run-hooks 'magik-session-kill-process-post-hook))))

(defun magik-session-query-interrupt-shell-subjob ()
  "Ask and then `comint-interrupt-subjob'."
  (interactive)
  (when (y-or-n-p "Kill the Magik process? ")
    (comint-kill-subjob)))

(defun magik-session-query-quit-shell-subjob ()
  "Ask and then `comint-quit-subjob'."
  (interactive)
  (when (y-or-n-p "Kill the Magik process? ")
    (comint-quit-subjob)))

(defun magik-session-query-stop-shell-subjob ()
  "Ask and then `comint-stop-subjob'."
  (interactive)
  (when (y-or-n-p "Suspend the Magik process? ")
    (comint-stop-subjob)))

(defun magik-session-query-shell-send-eof ()
  "Ask and then `comint-send-eof'."
  (interactive)
  (when (y-or-n-p "Send EOF to the Magik process? ")
    (comint-send-eof)))

;; R E C A L L I N G   C O M M A N D S
;; ___________________________________
;;
;;; Each gis command is recorded in `magik-session-history-ring' so that
;;; the user can recall and edit previous commands.  This section
;;; also adds dollars and implements the history-folding feature.

(defun magik-session--cmd-at-point ()
  "Return the command text at point if point is inside a previous command.
Detects command boundaries using `magik-session-prompt'.
Returns a cons (CMD-STRING . OFFSET) or nil."
  (let* ((proc (get-buffer-process (current-buffer)))
         (p (point))
         (proc-mark (and proc (process-mark proc))))
    (when (and proc-mark (< p proc-mark))
      (save-excursion
        (beginning-of-line)
        ;; Walk back to the prompt at the start of this command
        (unless (looking-at magik-session-prompt)
          (re-search-backward (concat "^" magik-session-prompt) nil t))
        (when (looking-at magik-session-prompt)
          (let ((cmd-start (match-end 0))
                (cmd-end (if (re-search-forward (concat "^" magik-session-prompt) proc-mark t)
                             (match-beginning 0)
                           proc-mark)))
            ;; Trim trailing whitespace/newlines from the command
            (setq cmd-end (save-excursion
                            (goto-char cmd-end)
                            (skip-chars-backward " \t\n" cmd-start)
                            (point)))
            (when (> cmd-end cmd-start)
              (cons (buffer-substring cmd-start cmd-end)
                    (- p cmd-start)))))))))

(defun magik-session--copy-cmd-to-process-mark (str offset)
  "Replace current input with STR and position cursor at OFFSET."
  (let ((mark (process-mark (get-buffer-process (current-buffer)))))
    (delete-region mark (point-max))
    (goto-char (point-max))
    (insert str)
    (let ((len (length str)))
      (forward-char (- (max 0 (min len offset)) len)))
    (when (pos-visible-in-window-p)
      (while (not (pos-visible-in-window-p (point-max)))
        (scroll-up 1)))))

(defun magik-session-send-region (beg end)
  "Record the region BEG to END in the history ring and send to the process.
Also append the string to \" *history*`buffer-name'\"."
  (let ((str (buffer-substring beg end)))
    (with-current-buffer (get-buffer-create (concat " *history*" (buffer-name)))
      (magik-mode)
      (let ((orig-point (point)))
        (goto-char (point-max))
        (insert str "\n")))
    ;; Store in ring history (strip trailing newlines/whitespace)
    (when magik-session-history-ring
      (ring-insert magik-session-history-ring
                   (string-trim-right str "[ \t\n]+"))
      (setq magik-session-history-index nil)))
  (set-marker comint-last-input-start beg)
  (set-marker comint-last-input-end   end)
  (set-marker (process-mark (get-buffer-process (current-buffer))) end)
  (goto-char (point-max))
  (process-send-region (get-buffer-process (current-buffer)) beg end))

(defun magik-session-beginning-of-line (&optional n)
  "Move point to beginning of Nth line or just after prompt.
If command is repeated then place point at beginning of prompt."
  (interactive "^p")
  (beginning-of-line n)
  ;;Only move to end of prompt if last-command was this one
  ;;AND a prefix key has not be used (n=1).
  (and (not (and (eq last-command 'magik-session-beginning-of-line) (eq n 1)))
       (looking-at magik-session-prompt)
       (goto-char (match-end 0))))

                                        ; paulw - mods to make pre/post SW5 work in a single emacs
                                        ; see also swkeys.el for key definition

(defun magik-session-toggle-dollar ()
  "Toggle auto-insertion of $ terminator."
  (interactive)
  (setq magik-session-auto-insert-dollar (not magik-session-auto-insert-dollar))
  (message "Insert dollar now %s" (if (symbol-value magik-session-auto-insert-dollar) "enabled" "disabled")))

(defun magik-session-newline (arg)
  "If in a previous cmd, recall.
If within current cmd, insert a newline.
If at end of current cmd and cmd is complete, send to gis.
If at end of current cmd and cmd is not complete, insert a newline.
Else (not in any cmd) recall line."
  (interactive "*P")
  (let
      ((cmd-info (magik-session--cmd-at-point))
       (p (process-mark (get-buffer-process (current-buffer)))))
    (cond
     (cmd-info  ; in a prev. cmd.
      (magik-session--copy-cmd-to-process-mark (car cmd-info) (cdr cmd-info)))

     ((>= (point) p)
      (when abbrev-mode
        (save-excursion
          (expand-abbrev)))
      (cond
       ((looking-at "[ \t\n]*\\'")  ; at end of curr. cmd.
        (newline arg)
        (cond
         ((save-excursion
            (and (progn
                   (skip-chars-backward " \t\n")
                   (eq (preceding-char) ?$))
                 (> (point) p)))
          (skip-chars-backward " \t\n")
          (forward-char)
          (delete-region (point) (point-max))
          (magik-session-send-region (marker-position p) (point)))
         ((magik-session--complete-magik-p p (point))
                                        ;          (insert "$\n") ;; paulw - remove additional <CR> which messes with pling variables
          (when magik-session-auto-insert-dollar
            (insert "$\n"))
          (delete-region (point) (point-max))
          (magik-session-send-region (marker-position p) (point)))))
       ((looking-at "[ \t\n]*\\$[ \t\n]*\\'")
        (if (magik-session--complete-magik-p p (point))
            (progn
              (search-forward "$")
              (delete-region (point) (point-max))
              (insert "\n")
              (magik-session-send-region (marker-position p) (point)))
          (newline arg)))
       (t
        (newline arg))))

     (t  ; not in any cmd.
      (delete-region (process-mark (get-buffer-process (current-buffer))) (point-max))
      (let
          ((str (buffer-substring (line-beginning-position) (line-end-position)))
           (n (- (line-end-position) (point))))
        (goto-char (point-max))
        (insert str)
        (backward-char n))))))

(defun magik-session--complete-magik-p (beg end)
  "Return t if the region from BEG to END is a syntactically piece of Magik.
Also write a message saying why the magik is not complete."
  (save-excursion
    (goto-char beg)
    (let
        (stack  ; ...of pending brackets and keywords (strings).
         last-tok)
      (while
          (progn
            (let
                ((toks (magik-tokenise-region-no-eol-nor-point-min (point) (min (line-end-position) end))))
              (when toks
                (setq last-tok (car (last toks))))
              (dolist (tok toks)
                (cond
                 ((or (and (equal (car stack) "_for")    (equal (car tok) "_over"))
                      (and (equal (car stack) "_over")   (equal (car tok) "_loop"))
                      (and (equal (car stack) "_pragma") (equal (car tok) "_method"))
                      (and (equal (car stack) "_pragma") (equal (car tok) "_proc")))
                  (pop stack)
                  (push (car tok) stack))
                 ((member (car tok) '("_for" "_over" "_pragma"))
                  (push (car tok) stack))
                 ((assoc (car tok) magik-begins-and-ends)
                  (push (car tok) stack))
                 ((assoc (car tok) magik-ends-and-begins)
                  (cond
                   ((null stack)
                    (error "Found '%s' with no corresponding '%s'"
                           (car tok)
                           (cdr (assoc (car tok) magik-ends-and-begins))))
                   ((equal (cdr (assoc (car tok) magik-ends-and-begins)) (car stack))
                    (pop stack))
                   (t
                    (error "Found '%s' when expecting '%s'"
                           (car tok)
                           (cdr (assoc (car stack) (append magik-begins-and-ends
                                                           '(("_for" . "_over")
                                                             ("_over" . "_loop")
                                                             ("_pragma" . "_proc or _method"))))))))))))
            (/= (line-end-position) (point-max)))
        (forward-line))
      (cond
       (stack
        (message "Not sent (waiting for '%s')."
                 (cdr (assoc (car stack) (append magik-begins-and-ends
                                                 '(("_for" . "_over")
                                                   ("_over" . "_loop")
                                                   ("_pragma" . "_proc or _method"))))))
        nil)
       ((assoc (car last-tok) magik-operator-precedences)
        (message "Not sent (there is a pending operator '%s')." (car last-tok))
        nil)
       (t
        t)))))

(defun magik-session--prepare-for-edit-cmd (_beg _end)
  "If point is in a previous command, copy it to the process mark for editing."
  (when-let* ((cmd-info (magik-session--cmd-at-point)))
    (magik-session--copy-cmd-to-process-mark (car cmd-info) (cdr cmd-info))))

(defun magik-session-send-command-at-point ()
  "Send the command at point.
Copying to the end of the buffer if necessary and don't add extra dollars."
  (interactive "*")
  (or (get-buffer-process (current-buffer))
      (error "There is no process running in this buffer"))
  (let ((cmd-info (magik-session--cmd-at-point))
        (p (process-mark (get-buffer-process (current-buffer)))))
    (cond
     (cmd-info
      (magik-session--copy-cmd-to-process-mark (car cmd-info) 0)
      (magik-session-send-region (marker-position p) (point-max)))
     ((>= (point)
          (save-excursion
            (goto-char p)
            (beginning-of-line)
            (point)))
      (goto-char (point-max))
      (or (eq (preceding-char) ?\n)
          (insert ?\n))
      (magik-session-send-region (marker-position p) (point-max)))
     (t
      (error "Not a command")))))

(defun magik-session-recall-prev-cmd ()
  "Recall the previous command from the history ring.

The variable `magik-session-recall-cmd-move-to-end' decides
whether cursor point is placed at end of command.
Compare with \\[magik-session-recall-prev-matching-cmd]."
  (interactive "*")
  (magik-session--recall 1))

(defun magik-session-recall-next-cmd ()
  "Recall the next command from the history ring.

The variable `magik-session-recall-cmd-move-to-end' decides
whether cursor point is placed at end of command.
Compare with \\[magik-session-recall-next-matching-cmd]."
  (interactive "*")
  (magik-session--recall -1))

(defun magik-session-recall-prev-matching-cmd ()
  "Recall previous command matching text before point."
  (interactive "*")
  (let ((prefix (buffer-substring
                 (process-mark (get-buffer-process (current-buffer)))
                 (point))))
    (magik-session--recall 1 prefix)))

(defun magik-session-recall-next-matching-cmd ()
  "Recall next command matching text before point."
  (interactive "*")
  (let ((prefix (buffer-substring
                 (process-mark (get-buffer-process (current-buffer)))
                 (point))))
    (magik-session--recall -1 prefix)))

(defun magik-session--recall (step &optional match-prefix)
  "Recall a command from the history ring in direction STEP.
If MATCH-PREFIX is non-nil, only match commands starting with it."
  (or (get-buffer-process (current-buffer))
      (error "There is no process running in this buffer"))
  (when (ring-empty-p magik-session-history-ring)
    (user-error "No commands in history"))
  (let* ((ring magik-session-history-ring)
         (len (ring-length ring))
         (idx (or magik-session-history-index -1))
         (mark (process-mark (get-buffer-process (current-buffer))))
         found)
    ;; Search for next matching entry
    (setq idx (+ idx step))
    (while (and (not found) (>= idx 0) (< idx len))
      (let ((cmd (ring-ref ring idx)))
        (if (or (null match-prefix)
                (string-empty-p match-prefix)
                (string-prefix-p match-prefix cmd))
            (setq found cmd)
          (setq idx (+ idx step)))))
    (unless found
      (if (or (null match-prefix) (string-empty-p match-prefix))
          (user-error "No %s command" (if (> step 0) "previous" "next"))
        (user-error "No %s command matching '%s'"
                    (if (> step 0) "previous" "next") match-prefix)))
    (setq magik-session-history-index idx)
    ;; Replace current input with the recalled command
    (delete-region mark (point-max))
    (goto-char (point-max))
    (insert found)
    (when magik-session-recall-cmd-move-to-end
      (goto-char (point-max)))))

(defun magik-session--find-prompt-positions ()
  "Return a list of prompt positions (beginning of each prompt line) in the buffer.
Searches for `magik-session-prompt' from the start."
  (let (positions)
    (save-excursion
      (goto-char (point-min))
      (while (re-search-forward (concat "^" magik-session-prompt) nil t)
        (push (match-beginning 0) positions)))
    (nreverse positions)))

(defun magik-session-display-history (arg)
  "Fold (hide) away the parts of the Magik buffer in between the last ARG commands.
If ARG is null, use a default of `magik-session-history-length'."
  (interactive "*P")
  (setq arg (if (null arg) magik-session-history-length (prefix-numeric-value arg)))
  (let ((buf (if (derived-mode-p 'magik-session-mode)
                 (current-buffer)
               (get-buffer magik-session-buffer))))
    (with-current-buffer buf
      ;; Remove any existing fold overlays first.
      (remove-overlays (point-min) (point-max) 'magik-session-fold t)
      (let* ((positions (magik-session--find-prompt-positions))
             (total (length positions))
             (start-idx (max 0 (- total arg))))
        (when (< start-idx total)
          (message "Folding the last %s commands..." (number-to-string arg))
          ;; Hide everything before the first visible command.
          (let ((fold-end (nth start-idx positions)))
            (when (> fold-end (point-min))
              (let ((ov (make-overlay (point-min) fold-end)))
                (overlay-put ov 'invisible 'magik-session-fold)
                (overlay-put ov 'magik-session-fold t)
                (overlay-put ov 'before-string "...\n"))))
          ;; Hide output between commands.
          ;; The output region starts at the line *after* the prompt line
          ;; and ends just before the next prompt.
          (let ((i start-idx))
            (while (< i (1- total))
              (let ((output-start (save-excursion
                                    (goto-char (nth i positions))
                                    (forward-line 1)
                                    (point)))
                    (next-cmd-start (nth (1+ i) positions)))
                (when (< output-start next-cmd-start)
                  (let ((ov (make-overlay output-start next-cmd-start)))
                    (overlay-put ov 'invisible 'magik-session-fold)
                    (overlay-put ov 'magik-session-fold t)
                    (overlay-put ov 'before-string "\n"))))
              (cl-incf i)))
          (message "Folding the last %s commands...Done" (number-to-string arg)))))))

(defun magik-session-undisplay-history (_arg)
  "Unfold (show) all previously folded command history.
Removes all invisible overlays tagged with `magik-session-fold'."
  (interactive "*P")
  (let ((buf (if (derived-mode-p 'magik-session-mode)
                 (current-buffer)
               (get-buffer magik-session-buffer))))
    (with-current-buffer buf
      (message "Unfolding commands...")
      (remove-overlays (point-min) (point-max) 'magik-session-fold t)
      (message "Unfolding commands...Done"))))

(defun magik-session-goto-process-mark ()
  "(goto-char (process-mark (get-buffer-process (current-buffer))))."
  (interactive)
  (goto-char (process-mark (get-buffer-process (current-buffer)))))

(defun magik-session-set-process-mark-to-eob ()
  "(set-marker (process-mark (get-buffer-process (current-buffer))) (point-max))."
  (interactive)
  (set-marker (process-mark (get-buffer-process (current-buffer))) (point-max)))
;;;
;;;  T R A C E B A C K
;;;

;; support for `magik-session-traceback-print'
(defun magik-session-print-region-and-fold (start end switches)
  "Like `print-region-1' but with long lines folded first."
  (let ((name (concat (buffer-name) " Emacs buffer"))
        (width tab-width))
    (save-excursion
      (message "Printing...")
      (let ((oldbuf (current-buffer)))
        (set-buffer (get-buffer-create " *spool temp*"))
        (widen) (erase-buffer)
        (insert-buffer-substring oldbuf start end)
        (setq tab-width width)
        (untabify (point-min) (point-max))
        (goto-char (point-min))
        (while
            (not (eobp))
          (if (> (- (line-end-position) (point)) 72)
              (progn
                (forward-char 72)
                (insert ?\n))
            (forward-line)))
        (setq start (point-min) end (point-max)))
      (apply 'call-process-region
             (nconc (list start end lpr-command
                          nil nil nil)
                    (nconc (and (eq system-type 'berkeley-unix)
                                (list "-J" name "-T" name))
                           switches)))
      (message "Printing... Done"))))

(defun magik-session-error-narrow-region ()
  "Narrow region between the current Magik prompt."
  (narrow-to-region (save-excursion (re-search-backward magik-session-prompt))
                    (save-excursion
                      (or (re-search-forward magik-session-prompt nil t) (goto-char (point-max)))
                      (beginning-of-line)
                      (point))))

(defun magik-session-error-line-col (line)
  "Return (LINE . COLUMN) cons for location of error."
  (let ((col 0))
    (save-excursion
      (save-match-data
        (search-backward "--- line")
        (end-of-line)
        (forward-word -1)
        (setq line (+ line (string-to-number (current-word))))
        (when (re-search-forward "^\\s-*\\^" nil t)
          (setq col (1- (length (match-string 0)))))))
    (cons line col)))

(defun magik-session-error-goto ()
  "Goto file that contain the Magik error."
  (interactive)
  (let ((case-fold-search nil) ;case-sensitive searching required for "Loading"
        (line-adjust 0)
        (pos 0)
        file line-col buf)
    (save-match-data
      (save-restriction
        (magik-session-error-narrow-region)
        (save-excursion
          (beginning-of-line)
          (when (looking-at (concat "^\\*\\*\\*\\*.*" "on line" " \\([0-9]+\\)$"))
            (setq line-col (magik-session-error-line-col (string-to-number (match-string-no-properties 1)))
                  file (and (save-excursion (re-search-backward "Loading \\(.*\\)" nil t))
                            (match-string-no-properties 1)))
            (if (file-exists-p file)
                (setq buf (or (find-buffer-visiting file) (find-file-noselect file)))
              (when (re-search-backward "^\\*\\*\\*\\* Emacs: buffer=\\(.*\\) file=\\(.*\\) position=\\([0-9]+\\)" nil t)
                (setq buf  (match-string-no-properties 1)
                      file (match-string-no-properties 2)
                      pos  (string-to-number (match-string-no-properties 3))
                      line-adjust -4)))))))
    (or file
        (error "No Error on this line to go to"))
    (pop-to-buffer buf)
    (goto-char pos)

    ;;Subtract line-adjust lines because we add lines
    ;;to the transmitted buffer and Magik counts lines from 0.
    (forward-line (+ (car line-col) line-adjust))

    (move-to-column (cdr line-col))))

(defun magik-session-error-goto-mouse (click)
  "Goto error at mouse point CLICK."
  (interactive "e")
  (mouse-set-point click)
  (magik-session-error-goto))

(defun magik-session-traceback-print ()
  "Send the text from the most recent error to the end of the buffer to the print.
Query first for \"**** Error\"."
  (interactive)
  (save-excursion
    (goto-char (point-max))
    (if (search-backward "\n**** Error" nil t)
        (when (y-or-n-p (concat (format "Print the last traceback (%s lines)?"
                                        (number-to-string (count-lines (point) (point-max)))) " "))
          (magik-session-print-region-and-fold (point) (point-max) nil))
      (error "Couldn't find a line starting with '**** Error' - nothing printed" ))))

(defun magik-session-traceback-save ()
  "Save in \"~/traceback.txt\" all the text onwards from the most recent error.
An error is is searched using \"**** Error\"."
  (interactive)
  (save-excursion
    (goto-char (point-max))
    (if (search-backward "\n**** Error" nil t)
        (progn
          (write-region (point) (point-max) "~/traceback.txt")
          (message "Saved the traceback in '~/traceback.txt'."))
      (error "Couldn't find a line starting with '**** Error' - nothing saved"))))

(defun magik-session-traceback-up ()
  "Move up buffer to the previous traceback."
  (interactive)
  (if (re-search-backward "---- traceback: " nil t)
      (forward-line -1)
    (user-error "No previous traceback found")))

(defun magik-session-traceback-down ()
  "Move down buffer to the next traceback."
  (interactive)
  (forward-line 2)
  (if (re-search-forward "---- traceback: " nil t)
      (forward-line -1)
    (forward-line -2)
    (user-error "No next traceback found")))

;;; Drag 'n' Drop
;;
;; When a file is dragged and dropped and the current buffer is
;; as Magik mode buffer, the file is loaded into the Magik session.

(defun magik-session-drag-n-drop-mode (&optional value)
  "Toggle Drag and drop Magik loading functionality using VALUE."
  (interactive "P")
  (setq magik-session-drag-n-drop-mode
        (if (null value)
            (not magik-session-drag-n-drop-mode)
          (> (prefix-numeric-value value) 0)))
  (add-hook 'find-file-hook 'magik-session-drag-n-drop-load)
  (message "Magik 'Drag and Drop' file mode is %s"
           (if magik-session-drag-n-drop-mode "on" "off"))
  (force-mode-line-update))

(defun magik-session-drag-n-drop-load ()
  "Load a drag and dropped file into the Magik Session.
If the previous buffer was a Magik session buffer and the previous event was
a drag & drop event then we load the dropped file into the Magik session.

The file must be in a Major mode that defines the function:
  MODE-drag-n-drop-load
where MODE is the name of the major mode with the '-mode' postfix."
  (let (fn gis)
    ;;hopefully the tests are done in the cheapest, most efficient order
    ;;but gis-drag-n-drop-mode is checked last in case user has set
    ;;up a per-buffer Drag 'n' drop mode
    (when (and (listp last-input-event)
               (eq (car last-input-event) 'drag-n-drop)
               (setq fn (intern (concat (substring (symbol-name major-mode) 0 -5)
                                        "-drag-n-drop-load")))
               (fboundp fn)
               (windowp (caadr last-input-event))
               (setq gis (window-buffer (caadr last-input-event)))
               (with-current-buffer gis


                 (and magik-session-drag-n-drop-mode
                      (derived-mode-p 'magik-session-mode))))
      (funcall fn gis (buffer-file-name)))))

(defun magik-session-disable-save ()
  "Like `save-buffer', but does nothing in magik-session-mode."
  (interactive)
  (message "Can't save Magik Session buffer."))

;;;Package registration

;;Ensure Default magik-session-command are placed at head of magik-session-command-history
(mapc (function
       (lambda (c)
         (and c
              (not (member c magik-session-command-history))
              (push c magik-session-command-history))))
      (list magik-session-command-default magik-session-command))

;;; package setup via setting of variable before load.
(and magik-session-drag-n-drop-mode (magik-session-drag-n-drop-mode magik-session-drag-n-drop-mode))

(or (assq 'magik-session-drag-n-drop-mode minor-mode-alist)
    (push '(magik-session-drag-n-drop-mode magik-session-drag-n-drop-mode-line-string) minor-mode-alist))

;;MSB configuration
(defun magik-session-msb-configuration ()
  "Add Magik buffers to MSB menu, supposes that MSB is already loaded."
  (let* ((l (length msb-menu-cond))
         (last (nth (1- l) msb-menu-cond))
         (precdr (nthcdr (- l 2) msb-menu-cond)) ; cdr of this is last
         (handle (1- (nth 1 last))))
    (setcdr precdr (list
                    (list
                     '(derived-mode-p 'magik-session-mode)
                     handle
                     "Magik (%d)")
                    last))))

(with-eval-after-load 'msb
  (magik-session-msb-configuration))

(defvar magik-session-mode-error-map (make-sparse-keymap)
  "Keymap for Jumping to error messages.")

(progn
  ;; ------------------------ magik session mode ------------------------

  (define-key magik-session-mode-error-map [mouse-2]  'magik-session-error-goto-mouse)
  (define-key magik-session-mode-error-map [C-return] 'magik-session-error-goto)

  ;; Basic interaction
  (define-key magik-session-mode-map "\ep"       'magik-session-recall-prev-cmd)
  (define-key magik-session-mode-map "\en"       'magik-session-recall-next-cmd)
  (define-key magik-session-mode-map "\r"        'magik-session-newline)
  (define-key magik-session-mode-map " "         'magik-yas-maybe-expand)
  (define-key magik-session-mode-map "\C-a"      'magik-session-beginning-of-line)
  (define-key magik-session-mode-map (kbd "C-c RET") 'magik-session-send-command-at-point)

  ;; Process control — comint conventions
  (define-key magik-session-mode-map "\C-c\C-c"  'magik-session-kill-process)
  (define-key magik-session-mode-map "\C-c\C-\\" 'magik-session-query-quit-shell-subjob)
  (define-key magik-session-mode-map "\C-c\C-z"  'magik-session-query-stop-shell-subjob)
  (define-key magik-session-mode-map "\C-c\C-d"  'magik-session-query-shell-send-eof)

  ;; History
  (define-key magik-session-mode-map (kbd "C-c C-p") 'magik-session-display-history)
  (define-key magik-session-mode-map (kbd "C-c C-n") 'magik-session-undisplay-history)
  (define-key magik-session-mode-map (kbd "C-c C-r") 'magik-session-recall-prev-matching-cmd)
  (define-key magik-session-mode-map (kbd "C-c C-s") 'magik-session-recall-next-matching-cmd)
  (define-key magik-session-mode-map (kbd "C-c C-i") 'magik-completion-invalidate-cache)

  ;; Traceback
  (define-key magik-session-mode-map (kbd "C-c C-t") 'magik-session-traceback-print)
  (define-key magik-session-mode-map (kbd "C-c C-u") 'magik-session-traceback-up)
  (define-key magik-session-mode-map (kbd "C-c C-o") 'magik-session-traceback-down)
  (define-key magik-session-mode-map (kbd "C-c C-v") 'magik-session-traceback-save)

  ;; Navigation and error handling
  (define-key magik-session-mode-map (kbd "C-c C-g") 'magik-session-error-goto)
  (define-key magik-session-mode-map (kbd "C-c C-f") 'magik-session-filter-toggle-filter)
  (define-key magik-session-mode-map (kbd "C-c C-$") 'magik-session-shell)

  ;; Work buffer
  (define-key magik-session-mode-map (kbd "C-c C-e m") 'magik-copy-method-to-buffer)
  (define-key magik-session-mode-map (kbd "C-c C-e r") 'magik-copy-region-to-buffer)
  (define-key magik-session-mode-map (kbd "C-c C-e s") 'magik-add-debug-statement)
  (define-key magik-session-mode-map (kbd "C-c C-e n") 'magik-set-work-buffer-name)

  (define-key magik-session-mode-map [remap save-buffer] 'magik-session-disable-save))

(provide 'magik-session)
;;; magik-session.el ends here
