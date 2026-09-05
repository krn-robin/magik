;;; magik-keys.el --- bind all the Magik keys, menus and mouse actions.  -*- lexical-binding: t; -*-

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

;; Key bindings for magik-mode follow standard Emacs conventions:
;;
;; - All mode-specific bindings use the C-c C-<control> prefix reserved
;;   for major modes.
;; - No function keys (F5-F9) are used, as these are reserved for users.
;; - No global bindings are set by default; all bindings are mode-local.
;;
;; The `magik-global-bindings' function is retained for backward
;; compatibility but is deprecated.  Use `magik-legacy-keys-mode' to
;; restore the old F-key based bindings during migration.

;;; Code:

(eval-when-compile
  (require 'magik-utils)
  (require 'magik-mode)
  (require 'magik-session)
  (require 'magik-cb))

(require 'magik-menu)

(defun magik-customize ()
  "Open Customization buffer for Smallword Development."
  (interactive)
  (customize-group 'magik))

;;; Legacy keybindings (deprecated)

(defvar magik-legacy-keys-mode-map
  (let ((map (make-sparse-keymap)))
    ;; Top-level F-key globals (F5-F9 are user-reserved per GNU convention)
    (define-key map [f6]    'magik-copy-method)
    (define-key map [f7]    'magik-transmit-method)
    (define-key map [f8]    'magik-transmit-region)
    (define-key map [f9]    'magik-mark-method)

    ;; F2 prefix
    (define-key map (kbd "<f2> <f7>")    'magik-transmit-method)
    (define-key map (kbd "<f2> <f8>")    'magik-transmit-region)
    (define-key map (kbd "<f2> RET")     'magik-transmit-thing)
    (define-key map (kbd "<f2> #")       'magik-comment-region)
    (define-key map (kbd "<f2> ESC #")   'magik-uncomment-region)
    (define-key map (kbd "<f2> b")       'magik-transmit-buffer)
    (define-key map (kbd "<f2> m")       'magik-transmit-method)
    (define-key map (kbd "<f2> r")       'magik-transmit-region)
    (define-key map (kbd "<f2> q")       'magik-fill-public-comment)
    (define-key map (kbd "<f2> t")       'magik-trace-curr-statement)
    (define-key map (kbd "<f2> SPC")     'magik-explicit-electric-space)
    (define-key map (kbd "<f2> e")       'magik-electric-mode)
    (define-key map (kbd "<f2> s")       'magik-version-selection)
    (define-key map (kbd "<f2> z")       'magik-session)

    ;; F3 prefix
    (define-key map (kbd "<f3> <f3>")    'magik-cb)
    (define-key map (kbd "<f3> b")       'magik-cb-paste-method-and-class)
    (define-key map (kbd "<f3> c")       'magik-cb-paste-class)
    (define-key map (kbd "<f3> j")       'magik-cb-jump-to-source)
    (define-key map (kbd "<f3> m")       'magik-cb-paste-method)
    (define-key map (kbd "<f3> /")       'magik-cb-and-clear)
    map)
  "Keymap for `magik-legacy-keys-mode'.
Provides the old F-key based global bindings for backward compatibility.")

;;;###autoload
(define-minor-mode magik-legacy-keys-mode
  "Minor mode providing legacy F-key bindings for magik-mode.

This mode restores the pre-2025 global keybinding scheme that used
F2, F3, F4, F6, F7, F8, and F9 as global prefix keys and shortcuts.

These bindings violate Emacs conventions (F5-F9 are reserved for
users, and global bindings should not be set by major mode packages).
This mode is provided solely for backward compatibility during
migration to the new C-c based bindings.

\\{magik-legacy-keys-mode-map}"
  :global t
  :lighter " MagikLegacy"
  :group 'magik)

;;;###autoload
(defun magik-global-bindings ()
  "Setup the old Smallworld key bindings.

This function is DEPRECATED.  The new keybinding scheme uses standard
Emacs C-c prefixed bindings local to each major mode.  To restore the
old F-key based global bindings, enable `magik-legacy-keys-mode'
instead."
  (declare (obsolete magik-legacy-keys-mode "2025"))
  (magik-legacy-keys-mode 1))

(provide 'magik-keys)
;;; magik-keys.el ends here
