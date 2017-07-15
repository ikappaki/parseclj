;;; clj-lex.el --- Clojure/EDN Lexer

;; Copyright (C) 2017  Arne Brasseur

;; Author: Arne Brasseur <arne@arnebrasseur.net>

;; This file is not part of GNU Emacs.

;; This file is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.

;; This file is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs; see the file COPYING.  If not, write to
;; the Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
;; Boston, MA 02110-1301, USA.

;;; Commentary:

;; A reader for EDN data files and parser for Clojure source files.

(require 'dash)

(defun clj-lex-token (type form pos &rest args)
  `((type . ,type)
    (form . ,form)
    (pos  . ,pos)
    ,@(mapcar (lambda (pair)
                (cons (car pair) (cadr pair)))
              (-partition 2 args))))

(defun clj-lex-token-type (token)
  (and (listp token)
       (cdr (assq 'type token))))

(defun clj-lex-token? (token)
  (and (listp token)
       (consp (car token))
       (eq 'type (caar token))
       (not (listp (cdar token)))))

(defun clj-lex-at-whitespace? ()
  (let ((char (char-after (point))))
    (or (equal char ?\ )
        (equal char ?\t)
        (equal char ?\n)
        (equal char ?\r)
        (equal char ?,))))

(defun clj-lex-at-eof? ()
  (eq (point) (point-max)))

(defun clj-lex-whitespace ()
  (let ((pos (point)))
    (while (clj-lex-at-whitespace?)
      (right-char))
    (clj-lex-token :whitespace
                   (buffer-substring-no-properties pos (point))
                   pos)))

(defun clj-lex-skip-digits ()
  (while (and (char-after (point))
              (<= ?0 (char-after (point)))
              (<= (char-after (point)) ?9))
    (right-char)))

(defun clj-lex-skip-number ()
  ;; [\+\-]?\d+\.\d+
  (when (member (char-after (point)) '(?+ ?-))
    (right-char))

  (clj-lex-skip-digits)

  (when (eq (char-after (point)) ?.)
    (right-char))

  (clj-lex-skip-digits))

(defun clj-lex-number ()
  (let ((pos (point)))
    (clj-lex-skip-number)

    ;; 10110r2 or 4.3e+22
    (when (member (char-after (point)) '(?E ?e ?r))
      (right-char))

    (clj-lex-skip-number)

    ;; trailing M
    (when (eq (char-after (point)) ?M)
      (right-char))

    (let ((char (char-after (point))))
      (if (and char (or (and (<= ?a char) (<= char ?z))
                        (and (<= ?A char) (<= char ?Z))
                        (and (member char '(?. ?* ?+ ?! ?- ?_ ?? ?$ ?& ?= ?< ?> ?/)))))
          (progn
            (right-char)
            (clj-lex-token :lex-error
                           (buffer-substring-no-properties pos (point))
                           pos
                           'error-type :invalid-number-format))

        (clj-lex-token :number
                       (buffer-substring-no-properties pos (point))
                       pos)))))


(defun clj-lex-digit? (char)
  (and char (<= ?0 char) (<= char ?9)))

(defun clj-lex-at-number? ()
  (let ((char (char-after (point))))
    (or (clj-lex-digit? char)
        (and (member char '(?- ?+ ?.))
             (clj-lex-digit? (char-after (1+ (point))))))))

(defun clj-lex-symbol-start? (char &optional alpha-only)
  "Symbols begin with a non-numeric character and can contain
alphanumeric characters and . * + ! - _ ? $ % & = < >. If -, + or
. are the first character, the second character (if any) must be
non-numeric.

In some cases, like in tagged elements, symbols are required to
start with alphabetic characters only. ALPHA-ONLY ensures this
behavior."
  (not (not (and char
                 (or (and (<= ?a char) (<= char ?z))
                     (and (<= ?A char) (<= char ?Z))
                     (and (not alpha-only) (member char '(?. ?* ?+ ?! ?- ?_ ?? ?$ ?% ?& ?= ?< ?> ?/))))))))

(defun clj-lex-symbol-rest? (char)
  (or (clj-lex-symbol-start? char)
      (clj-lex-digit? char)
      (eq ?: char)
      (eq ?# char)))

(defun clj-lex-get-symbol-at-point (pos)
  "Return the symbol at point."
  (while (clj-lex-symbol-rest? (char-after (point)))
    (right-char))
  (buffer-substring-no-properties pos (point)))

(defun clj-lex-symbol ()
  (let ((pos (point)))
    (right-char)
    (let ((sym (clj-lex-get-symbol-at-point pos)))
      (cond
       ((equal sym "nil") (clj-lex-token :nil "nil" pos))
       ((equal sym "true") (clj-lex-token :true "true" pos))
       ((equal sym "false") (clj-lex-token :false "false" pos))
       (t (clj-lex-token :symbol sym pos))))))

(defun clj-lex-string ()
  (let ((pos (point)))
    (right-char)
    (while (not (or (equal (char-after (point)) ?\") (clj-lex-at-eof?)))
      (if (equal (char-after (point)) ?\\)
          (right-char 2)
        (right-char)))
    (if (equal (char-after (point)) ?\")
        (progn
          (right-char)
          (clj-lex-token :string (buffer-substring-no-properties pos (point)) pos))
      (clj-lex-token :lex-error (buffer-substring-no-properties pos (point)) pos))))

(defun clj-lex-lookahead (n)
  (buffer-substring-no-properties (point) (min (+ (point) n) (point-max))))

(defun clj-lex-character ()
  (let ((pos (point)))
    (right-char)
    (cond
     ((equal (clj-lex-lookahead 3) "tab")
      (right-char 3)
      (clj-lex-token :character (buffer-substring-no-properties pos (point)) pos))

     ((equal (clj-lex-lookahead 5) "space")
      (right-char 5)
      (clj-lex-token :character (buffer-substring-no-properties pos (point)) pos))

     ((equal (clj-lex-lookahead 6) "return")
      (right-char 6)
      (clj-lex-token :character (buffer-substring-no-properties pos (point)) pos))

     ((equal (clj-lex-lookahead 7) "newline")
      (right-char 7)
      (clj-lex-token :character (buffer-substring-no-properties pos (point)) pos))

     ((equal (char-after (point)) ?u)
      (right-char 5)
      (clj-lex-token :character (buffer-substring-no-properties pos (point)) pos))

     ((equal (char-after (point)) ?o)
      (right-char 4)
      (clj-lex-token :character (buffer-substring-no-properties pos (point)) pos))

     (t
      (right-char)
      (clj-lex-token :character (buffer-substring-no-properties pos (point)) pos)))))

(defun clj-lex-keyword ()
  (let ((pos (point)))
    (right-char)
    (when (equal (char-after (point)) ?:) ;; same-namespace keyword
      (right-char))
    (if (equal (char-after (point)) ?:) ;; three colons in a row => lex-error
        (progn
          (right-char)
          (clj-lex-token :lex-error (buffer-substring-no-properties pos (point)) pos 'error-type :invalid-keyword))
      (progn
        (while (or (clj-lex-symbol-rest? (char-after (point)))
                   (equal (char-after (point)) ?#))
          (right-char))
        (clj-lex-token :keyword (buffer-substring-no-properties pos (point)) pos)))))

(defun clj-lex-comment ()
  (let ((pos (point)))
    (goto-char (line-end-position))
    (when (equal (char-after (point)) ?\n)
      (right-char))
    (clj-lex-token :comment (buffer-substring-no-properties pos (point)) pos)))

(defun clj-lex-next ()
  (if (clj-lex-at-eof?)
      (clj-lex-token :eof nil (point))
    (let ((char (char-after (point)))
          (pos  (point)))
      (cond
       ((clj-lex-at-whitespace?)
        (clj-lex-whitespace))

       ((equal char ?\()
        (right-char)
        (clj-lex-token :lparen "(" pos))

       ((equal char ?\))
        (right-char)
        (clj-lex-token :rparen ")" pos))

       ((equal char ?\[)
        (right-char)
        (clj-lex-token :lbracket "[" pos))

       ((equal char ?\])
        (right-char)
        (clj-lex-token :rbracket "]" pos))

       ((equal char ?{)
        (right-char)
        (clj-lex-token :lbrace "{" pos))

       ((equal char ?})
        (right-char)
        (clj-lex-token :rbrace "}" pos))

       ((clj-lex-at-number?)
        (clj-lex-number))

       ((clj-lex-symbol-start? char)
        (clj-lex-symbol))

       ((equal char ?\")
        (clj-lex-string))

       ((equal char ?\\)
        (clj-lex-character))

       ((equal char ?:)
        (clj-lex-keyword))

       ((equal char ?\;)
        (clj-lex-comment))

       ((equal char ?#)
        (right-char)
        (let ((char (char-after (point))))
          (cond
           ((equal char ?{)
            (right-char)
            (clj-lex-token :set "#{" pos))
           ((equal char ?_)
            (right-char)
            (clj-lex-token :discard "#_" pos))
           ((clj-lex-symbol-start? char t)
            (right-char)
            (clj-lex-token :tag (concat "#" (clj-lex-get-symbol-at-point (1+ pos))) pos))
           (t
            (while (not (or (clj-lex-at-whitespace?)
                            (clj-lex-at-eof?)))
              (right-char))
            (clj-lex-token :lex-error (buffer-substring-no-properties pos (point)) pos 'error-type :invalid-hashtag-dispatcher)))))

       (t
        (concat ":(" (char-to-string char)))))))

(provide 'clj-lex)

;;; clj-lex.el ends here
