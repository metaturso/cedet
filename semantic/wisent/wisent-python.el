;;; wisent-python.el --- LALR grammar for Python
;;
;; Copyright (C) 2002 Richard Kim
;;
;; Author: Richard Kim <ryk@dspwiz.com>
;; Maintainer: Richard Kim <ryk@dspwiz.com>
;; Created: June 2002
;; Keywords: syntax
;; X-RCS: $Id: wisent-python.el,v 1.24 2003-01-31 04:16:26 emacsman Exp $
;;
;; This file is not part of GNU Emacs.
;;
;; This program is free software; you can redistribute it and/or
;; modify it under the terms of the GNU General Public License as
;; published by the Free Software Foundation; either version 2, or (at
;; your option) any later version.
;;
;; This software is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;; General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs; see the file COPYING.  If not, write to the
;; Free Software Foundation, Inc., 59 Temple Place - Suite 330,
;; Boston, MA 02111-1307, USA.

;;; Commentary:
;;
;; This is a LALR python parser that follows the official python
;; grammar closely.  The official Grammar file from the Python source
;; code distribution was the starting point of this version.
;;
;; Approximate non-terminal (NT) hierarchy of the python grammer for
;; the `single_input' NT is shown below.
;;
;;   goal
;;     single_input
;;       NEWLINE
;;       simple_stmt
;;         small_stmt_list semicolon_opt NEWLINE
;;           small_stmt
;;             print_stmt
;;             del_stmt
;;             pass_stmt
;;             flow_stmt
;;             import_stmt
;;             global_stmt
;;             exec_stmt
;;             assert_stmt
;;             expr_stmt
;;               augassign
;;               testlist
;;                 test
;;                   test_testlambdef
;;                   test_test
;;                     and_test
;;                       not_test
;;                         comparison
;;                           expr
;;                             xor_expr
;;                               and_expr
;;                                 shift_expr
;;                                   arith_expr
;;                                     term
;;                                       factor
;;                                         power
;;                                           atom
;;                                           trailer
;;                                             ( arglist_opt )
;;                                               test
;;                                             [ subscriptlist ]
;;       compound_stmt NEWLINE
;;         if_stmt
;;         while_stmt
;;         for_stmt
;;         try_stmt
;;         funcdef
;;         classdef

;;; To do:
;;
;; * Debug the grammar so that it can parse at least all standard *.py
;;   files distributed along with python.
;;
;; * Modify the grammar to take advantage of scan-lists advice, i.e.,
;;   generate INDENT_BLOCK tokens such as PAREN_BLOCK tokens rather than
;;   generating whole bunch of lexical tokens.

(require 'wisent-bovine)

;;;****************************************************************************
;;;@ Support Code
;;;****************************************************************************
;;
;; Some of these need to come before `wisent-python-default-setup' so that
;; symbols are defined before their first use.

;; Indentation stack to keep track of INDENT tokens generated without
;; matching DEDENT tokens. Generation of each INDENT token results in
;; a new integer being added to the beginning of this list where the
;; integer represents the indentation of the current line. Each time a
;; DEDENT token is generated, the latest entry is popped off
;; this list.
(defvar wisent-python-lexer-indent-stack '(0))

(defconst wisent-python-string-re "[rR]?[uU]?['\"]"
  "Regexp matching beginning of a python string.")

;; Limit string to 16 chars.
(defun wisent-python-truncate-string (s)
  (let ((len (length s)))
    (substring s 0 (if (> len 16) 16 len))))

;;;****************************************************************************
;;;@ New Lexer
;;;****************************************************************************

;; Pop all items from the "indent stack" if we are at end of region to parse.
;; This assumes that `end' variable is set.
(defun semantic-lex-python-pop-indent-stack ()
  (if (eq (point) end)
      (while (> (car wisent-python-lexer-indent-stack) 0)
	(semantic-lex-token 'DEDENT (point) (point))
	(pop wisent-python-lexer-indent-stack))))

(define-lex-analyzer semantic-lex-python-beginning-of-line
  "Handle beginning-of-line case, i.e., possibly generate INDENT or
DEDENT tokens by comparing current indentation level with the previous
indentation values stored in the wisent-python-lexer-indent-stack
stack."
  (and (bolp)
       (let ((last-indent (or (car wisent-python-lexer-indent-stack) 0))
	     (last-pos (point))
	     curr-indent)
	 (skip-chars-forward " \t")
	 (setq curr-indent (current-column))
	 ;;(message "semantic-lex-python-beginning-of-lin")
	 (cond
	  ;; Blank or comment line => no indentation change
	  ((looking-at "\\(#\\|$\\)")
	   (forward-line 1)
	   (setq end-point (point))
	   (semantic-lex-python-pop-indent-stack)
	   ;;(message "bol1: %s %s" start end-point)
	   t	;; Pos changed, so it is ok to return t here.
	   )
	  ;; No change in indentation.
	  ((= curr-indent last-indent)
	   (setq end-point (point))
	   ;; If pos did not change, then we must return nil so that
	   ;; other lexical analyzers can be run.
	   ;;(message "bol2: %s %s" start end-point)
	   nil)
	  ;; Indentation increased
	  ((> curr-indent last-indent)
	   ;; Return an INDENT lexical token
	   (push curr-indent wisent-python-lexer-indent-stack)
	   (semantic-lex-token 'INDENT last-pos (point))
	   ;;(message "bol3: %s %s" start end-point)
	   t	;; pos must have changed, so it is ok to return t.
	   )
	  ;; Indentation decreased
	  (t
	   ;; Pop one item from indentation stack
	   (while (< curr-indent last-indent)
	     (semantic-lex-token 'DEDENT last-pos (point))
	     (pop wisent-python-lexer-indent-stack)
	     (setq last-indent (or (car wisent-python-lexer-indent-stack) 0))
	     )
	   ;; If pos did not change, then we must return nil so that
	   ;; other lexical analyzers can be run.
	   ;;(message "bol4: %s %s" start end-point)
	   (not (eq last-pos (point))))
	  )))
  nil	;; all the work was done in the previous form
  )

(define-lex-analyzer semantic-lex-python-newline
  "Handle NEWLINE syntactic tokens.
If the following line is an implicit continuation of current line,
then throw away any immediately following INDENT and DEDENT tokens."
  (looking-at "\\(\n\\|\\s>\\)")
  ;;(message "semantic-lex-python-newline")
  (goto-char (match-end 0))
  (cond
   ;; If an unmatched open-paren exists, then no NEWLINE, INDENT, nor
   ;; DEDENT tokens are generated.  Simply move the point.
   ((> current-depth 0)
    (skip-chars-forward " \t")
    (setq end-point (point)))
   (t
    (semantic-lex-token 'NEWLINE (1- (point)) (point)))
   )
  (semantic-lex-python-pop-indent-stack)
  )

(define-lex-analyzer semantic-lex-python-string
  "Handle python strings."
  (looking-at wisent-python-string-re)
  (let ((opos (point))
	(e (condition-case nil
	       (progn
		 ;; skip over "r" and/or "u" characters if any
		 (goto-char (1- (match-end 0)))
		 (cond
		  ((looking-at "\"\"\"")
		   (forward-char 3)
		   (search-forward "\"\"\""))
		  (t
		   (forward-sexp 1)))
		 (point))
	     ;; This case makes flex
	     ;; robust to broken strings.
	     (error
	      (progn
		(goto-char
		 (funcall
		  semantic-flex-unterminated-syntax-end-function
		  'STRING_LITERAL
		  opos end))
		(point))))))
    (semantic-lex-token 'STRING_LITERAL opos e)))

(define-lex-analyzer semantic-lex-python-charquote
  "Handle BACKSLASH syntactic tokens."
  (looking-at "\\s\\+")
  (message "semantic-lex-python-charquote")
  (forward-char 1)
  (semantic-lex-token 'BACKSLASH (1- (point)) (point))
  (when (looking-at "\n")
    (forward-char 1)
    (skip-chars-forward " \t"))
  (setq end-point (point)))

;; This is same as wisent-java-lex-symbol except for using 'NAME token
;; rather than 'IDENTIFIER. -ryk1/05/03.
(define-lex-regex-analyzer semantic-lex-python-symbol
  "Detect and create identifier or keyword tokens."
  "\\(\\sw\\|\\s_\\)+"
  (semantic-lex-token
   (or (semantic-lex-keyword-p (match-string 0))
       'NAME)
   (match-beginning 0)
   (match-end 0)))

;; Same as wisent-java-lex-number. -ryk1/05/03.
(define-lex-simple-regex-analyzer semantic-lex-python-number
  "Detect and create number tokens."
  semantic-lex-number-expression 'NUMBER_LITERAL)

;; Same as wisent-java-lex-blocks. -ryk1/05/03.
(define-lex-block-analyzer semantic-lex-python-blocks
  "Detect and create a open, close or block token."
  (PAREN_BLOCK ("(" LPAREN) (")" RPAREN))
  (BRACE_BLOCK ("{" LBRACE) ("}" RBRACE))
  (BRACK_BLOCK ("[" LBRACK) ("]" RBRACK))
  )

(define-lex semantic-python-lexer
  "Lexical Analyzer for Python code."
  ;; semantic-lex-python-beginning-of-line needs to be the first so
  ;; that we don't miss any DEDENT tokens at the beginning of lines.
  semantic-lex-python-beginning-of-line
  ;; semantic-lex-python-string needs to come before symbols because
  ;; of the "r" and/or "u" prefix.
  semantic-lex-python-string
  semantic-lex-ignore-whitespace
  semantic-lex-python-newline
  semantic-lex-python-number	;; rather than semantic-lex-number
  semantic-lex-python-symbol	;; rather than semantic-lex-symbol-or-keyword
  semantic-lex-python-charquote
  semantic-lex-python-blocks	;; rather than semantic-lex-paren-or-list/semantic-lex-close-paren
  semantic-lex-ignore-comments
  semantic-lex-punctuation-type	;; rather than semantic-lex-punctuation
  semantic-lex-default-action
  )

(defun python-next-line ()
  "Move the cursor to the next line to check for INDENT or DEDENT tokens.
Usually this is simply the next line unless strings, lists, or blank lines,
or comment lines are encountered.  This function skips over such items."
  (let (beg)
    (while (not (eolp))
      (setq beg (point))
      (cond
       ;; skip over triple-quote string
       ((looking-at "\"\"\"")
	(forward-char 3)
	(search-forward "\"\"\""))
       ;; skip over lists, strings, etc
       ((looking-at "\\(\\s(\\|\\s\"\\|\\s<\\)")
	(forward-sexp 1))
       ;; skip over white space, word, symbol, and punctuation characters
       (t (skip-syntax-forward "-w_.")))
      (if (= (point) beg)
	  (error "You have found a bug in python-next-line")))
    ;; the point now should be at the end of a line
    (forward-line 1)
    (while (and (looking-at "\\s-*\\(\\s<\\|$\\)")
		(not (eobp))) ;; skip blank and comment lines
      (forward-line 1))))

(defun python-scan-lists ( &optional target-column )
  "Without actually changing the position, return the buffer position of
the next line whose indentation is the same as the current line or less
than current line."
  (or target-column (setq target-column (current-column)))
  (save-excursion
    (python-next-line)
    (while (> (current-indentation) target-column)
      (python-next-line))
    ;; Move the cursor to the original indentation level or first non-white
    ;; character which ever comes first.
    (skip-chars-forward " \t" (+ (point) target-column))
    (point)))

(defadvice scan-lists (around handle-python-mode activate compile)
  "Use python mode specific function, python-scan-lists, if the
current major mode is python-mode.
Otherwise simply call the original function."
  (if (and (eq major-mode 'python-mode)
	   (not (looking-at "\\s(")))
      (setq ad-return-value (python-scan-lists))
    ad-do-it))

(define-wisent-lexer wisent-python-lex
  "Return the next available lexical token in Wisent's form for Python.
The variable `wisent-lex-istream' contains the list of lexical tokens
produced by `semantic-lex'.  Pop the next token available and convert
it to a form suitable for the Wisent's parser."
  (let* ((tk (car wisent-lex-istream))
	 (tk-class (semantic-lex-token-class tk))
	 )
    (setq wisent-lex-istream (cdr wisent-lex-istream))
    (cond
     ((and (eq tk-class 'INDENT)
	   depth
	   (>= current-depth depth))
      (let ((beg (car (semantic-lex-token-bounds tk)))
	    (indent-count 1)
	    tk2 tk2-class end)
	(catch 'done
	  (while wisent-lex-istream
	    (setq tk2 (car wisent-lex-istream))
	    (cond
	     ((eq (semantic-lex-token-class tk2) 'DEDENT)
	      (setq indent-count (1- indent-count))
	      (when (= indent-count 0)
		(setq end (cdr (semantic-lex-token-bounds tk)))
		(throw 'done
		       (cons 'semantic-list
			     (cons (buffer-substring beg end)
				   (cons beg end))))))
	     ((eq (semantic-lex-token-class tk2) 'INDENT)
	      (setq indent-count (1+ indent-count)))
	     )
	    (setq wisent-lex-istream (cdr wisent-lex-istream)))
	  (error "Python lexer encountered an INDENT token without matching DEDENT")
	  )))
     (t
      (cons token-class
	    (cons (semantic-lex-token-text tk)
		  (semantic-lex-token-bounds tk))))
     )))

;; This should be called everytime before parsing starts.
;; Is there a better hook than python-mode-hook which gets called
;; at the start of every parse? -ryk6/21/02.

;;;###autoload
(add-hook 'python-mode-hook #'wisent-python-default-setup)

;;;****************************************************************************
;;;@ Code Filled in by wisent-wy-update-outputfile
;;;****************************************************************************

(defconst wisent-python-parser-tables
  ;;DO NOT EDIT! Generated from wisent-python.wy - 2003-01-30 20:10-0800
  (eval-when-compile
    (wisent-compile-grammar
     '((NEWLINE LPAREN RPAREN LBRACE RBRACE LBRACK RBRACK PAREN_BLOCK BRACE_BLOCK BRACK_BLOCK LTLTEQ GTGTEQ EXPEQ DIVDIVEQ DIVDIV LTLT GTGT EXPONENT EQ GE LE PLUSEQ MINUSEQ MULTEQ DIVEQ MODEQ AMPEQ OREQ HATEQ LTGT NE HAT LT GT AMP MULT DIV MOD PLUS MINUS PERIOD TILDE BAR COLON SEMICOLON COMMA ASSIGN BACKQUOTE BACKSLASH STRING_LITERAL NUMBER_LITERAL NAME INDENT DEDENT AND ASSERT BREAK CLASS CONTINUE DEF DEL ELIF ELSE EXCEPT EXEC FINALLY FOR FROM GLOBAL IF IMPORT IN IS LAMBDA NOT OR PASS PRINT RAISE RETURN TRY WHILE YIELD)
       nil
       (goal
	((NEWLINE))
	((simple_stmt))
	((compound_stmt)))
       (simple_stmt
	((small_stmt_list semicolon_opt NEWLINE)
	 (identity $1)))
       (small_stmt_list
	((small_stmt))
	((small_stmt_list SEMICOLON small_stmt)
	 (identity $1)))
       (small_stmt
	((expr_stmt))
	((print_stmt))
	((del_stmt))
	((pass_stmt))
	((flow_stmt))
	((import_stmt))
	((global_stmt))
	((exec_stmt))
	((assert_stmt)))
       (print_stmt
	((PRINT print_stmt_trailer)
	 (wisent-token $1 'code nil nil)))
       (print_stmt_trailer
	((test_list_opt)
	 (or $1 ""))
	((GTGT test trailing_test_list_with_opt_comma_opt)
	 (identity $2)))
       (trailing_test_list_with_opt_comma_opt
	(nil)
	((trailing_test_list comma_opt)
	 nil))
       (trailing_test_list
	((COMMA test)
	 nil)
	((trailing_test_list COMMA test)
	 nil))
       (expr_stmt
	((testlist expr_stmt_trailer)
	 (if
	     (and $2
		  (stringp $1)
		  (string-match "^\\(\\sw\\|\\s_\\)+$" $1))
	     (wisent-token $1 'variable nil nil)
	   (wisent-token $1 'code nil nil))))
       (expr_stmt_trailer
	((augassign testlist))
	((eq_testlist_zom)))
       (eq_testlist_zom
	(nil)
	((eq_testlist_zom ASSIGN testlist)
	 (identity $3)))
       (augassign
	((PLUSEQ))
	((MINUSEQ))
	((MULTEQ))
	((DIVEQ))
	((MODEQ))
	((AMPEQ))
	((OREQ))
	((HATEQ))
	((LTLTEQ))
	((GTGTEQ))
	((EXPEQ))
	((DIVDIVEQ)))
       (del_stmt
	((DEL exprlist)
	 (wisent-token $1 'code nil nil)))
       (exprlist
	((expr_list comma_opt)
	 (identity $1)))
       (expr_list
	((expr))
	((expr_list COMMA expr)
	 (format "%s, %s" $1 $3)))
       (pass_stmt
	((PASS)
	 (wisent-token $1 'code nil nil)))
       (flow_stmt
	((break_stmt))
	((continue_stmt))
	((return_stmt))
	((raise_stmt))
	((yield_stmt)))
       (break_stmt
	((BREAK)
	 (wisent-token $1 'code nil nil)))
       (continue_stmt
	((CONTINUE)
	 (wisent-token $1 'code nil nil)))
       (return_stmt
	((RETURN testlist_opt)
	 (wisent-token $1 'code nil nil)))
       (testlist_opt
	(nil)
	((testlist)))
       (yield_stmt
	((YIELD testlist)
	 (wisent-token $1 'code nil nil)))
       (raise_stmt
	((RAISE zero_one_two_or_three_tests)
	 (wisent-token $1 'code nil nil)))
       (zero_one_two_or_three_tests
	(nil
	 (identity ""))
	((test zero_one_or_two_tests)
	 (identity $1)))
       (zero_one_or_two_tests
	(nil)
	((COMMA test zero_or_one_comma_test)
	 nil))
       (zero_or_one_comma_test
	(nil)
	((COMMA test)
	 nil))
       (import_stmt
	((IMPORT dotted_as_name_list)
	 (wisent-token $2 'import nil nil))
	((FROM dotted_name IMPORT star_or_import_as_name_list)
	 (wisent-token $2 'import nil nil)))
       (dotted_as_name_list
	((dotted_as_name))
	((dotted_as_name_list COMMA dotted_as_name)
	 (identity $1)))
       (star_or_import_as_name_list
	((MULT)
	 nil)
	((import_as_name_list)
	 nil))
       (import_as_name_list
	((import_as_name)
	 nil)
	((import_as_name_list COMMA import_as_name)
	 nil))
       (import_as_name
	((NAME name_name_opt)
	 nil))
       (dotted_as_name
	((dotted_name name_name_opt)
	 (identity $1)))
       (name_name_opt
	(nil)
	((NAME NAME)
	 nil))
       (dotted_name
	((NAME))
	((dotted_name PERIOD NAME)
	 (format "%s.%s" $1 $3)))
       (global_stmt
	((GLOBAL comma_sep_name_list)
	 (wisent-token $1 'code nil nil)))
       (comma_sep_name_list
	((NAME))
	((comma_sep_name_list COMMA NAME)
	 (format "%s" $1)))
       (exec_stmt
	((EXEC expr exec_trailer)
	 (wisent-token $1 'code nil nil)))
       (exec_trailer
	(nil)
	((IN test comma_test_opt)
	 nil))
       (comma_test_opt
	(nil)
	((COMMA test)
	 nil))
       (assert_stmt
	((ASSERT test comma_test_opt)
	 (wisent-token $1 'code nil nil)))
       (compound_stmt
	((if_stmt))
	((while_stmt))
	((for_stmt))
	((try_stmt))
	((funcdef))
	((classdef)))
       (if_stmt
	((IF test COLON suite elif_suite_pair_list else_suite_pair_opt)
	 (wisent-token $1 'code nil nil)))
       (elif_suite_pair_list
	(nil)
	((elif_suite_pair_list ELIF test COLON suite)
	 nil))
       (else_suite_pair_opt
	(nil)
	((ELSE COLON suite)
	 nil))
       (suite
	((simple_stmt)
	 (list $1))
	((NEWLINE INDENT stmt_oom DEDENT)
	 (nreverse $3)))
       (stmt_oom
	((stmt)
	 (list $1))
	((stmt_oom stmt)
	 (cons $2 $1)))
       (stmt
	((simple_stmt))
	((compound_stmt)))
       (while_stmt
	((WHILE test COLON suite else_suite_pair_opt)
	 (wisent-token $1 'code nil nil)))
       (for_stmt
	((FOR exprlist IN testlist COLON suite else_suite_pair_opt)
	 (wisent-token $1 'code nil nil)))
       (try_stmt
	((TRY COLON suite except_clause_suite_pair_list else_suite_pair_opt)
	 (wisent-token $1 'code nil nil))
	((TRY COLON suite FINALLY COLON suite)
	 (wisent-token $1 'code nil nil)))
       (except_clause_suite_pair_list
	((except_clause COLON suite)
	 (concat "except_clause_suite_pair_list"))
	((except_clause_suite_pair_list except_clause COLON suite)
	 (concat "except_clause_suite_pair_list")))
       (except_clause
	((EXCEPT zero_one_or_two_test)))
       (zero_one_or_two_test
	(nil)
	((test zero_or_one_comma_test)))
       (funcdef
	((DEF NAME function_parameter_list COLON suite)
	 (wisent-token $2 'function nil $3)))
       (function_parameter_list
	((PAREN_BLOCK)
	 (semantic-parse-region
	  (car $region1)
	  (cdr $region1)
	  'function_parameters 1)))
       (function_parameters
	((LPAREN)
	 nil)
	((RPAREN)
	 nil)
	((function_parameter COMMA))
	((function_parameter RPAREN)))
       (function_parameter
	((fpdef_opt_test))
	((MULT NAME)
	 (wisent-token $2 'variable nil nil nil nil))
	((EXPONENT NAME)
	 (wisent-token $2 'variable nil nil nil nil)))
       (classdef
	((CLASS NAME paren_testlist_opt COLON suite)
	 (wisent-token $2 'type $1 $5 nil)))
       (paren_testlist_opt
	(nil)
	((PAREN_BLOCK)))
       (test
	((test_test))
	((lambdef)))
       (test_test
	((and_test))
	((test_test OR and_test)
	 (format "%s %s %s" $1 $2 $3)))
       (and_test
	((not_test))
	((and_test AND not_test)
	 (format "%s %s %s" $1 $2 $3)))
       (not_test
	((NOT not_test)
	 (format "NOT %s" $1))
	((comparison)))
       (comparison
	((expr))
	((comparison comp_op expr)
	 (format "%s %s %s" $1 $2 $3)))
       (comp_op
	((LT))
	((GT))
	((EQ))
	((GE))
	((LE))
	((LTGT))
	((NE))
	((IN))
	((NOT IN))
	((IS))
	((IS NOT)))
       (expr
	((xor_expr))
	((expr BAR xor_expr)
	 (format "%s %s %s" $1 $2 $3)))
       (xor_expr
	((and_expr))
	((xor_expr HAT and_expr)
	 (format "%s %s %s" $1 $2 $3)))
       (and_expr
	((shift_expr))
	((and_expr AMP shift_expr)
	 (format "%s %s %s" $1 $2 $3)))
       (shift_expr
	((arith_expr))
	((shift_expr shift_expr_operators arith_expr)
	 (format "%s %s %s" $1 $2 $3)))
       (shift_expr_operators
	((LTLT))
	((GTGT)))
       (arith_expr
	((term))
	((arith_expr plus_or_minus term)
	 (format "%s %s %s" $1 $2 $3)))
       (plus_or_minus
	((PLUS))
	((MINUS)))
       (term
	((factor))
	((term term_operator factor)
	 (format "%s %s %s" $1 $2 $3)))
       (term_operator
	((MULT))
	((DIV))
	((MOD))
	((DIVDIV)))
       (factor
	((prefix_operators factor)
	 (format "%s %s" $1 $2))
	((power)))
       (prefix_operators
	((PLUS))
	((MINUS))
	((TILDE)))
       (power
	((atom trailer_zom exponent_zom)
	 (concat $1
		 (if $2
		     (concat " " $2 " ")
		   "")
		 (if $3
		     (concat " " $3)
		   ""))))
       (trailer_zom
	(nil)
	((trailer_zom trailer)
	 (format "(%s %s)"
		 (or $1 "")
		 $2)))
       (exponent_zom
	(nil)
	((exponent_zom EXPONENT factor)
	 (format "(%s ** %s)"
		 (or $1 "")
		 $3)))
       (trailer
	((PAREN_BLOCK))
	((BRACK_BLOCK))
	((PERIOD NAME)
	 (concat "." $2)))
       (atom
	((PAREN_BLOCK)
	 (format "%s" $1))
	((BRACK_BLOCK)
	 (format "%s" $1))
	((BRACE_BLOCK)
	 (format "%s" $1))
	((BACKQUOTE testlist BACKQUOTE)
	 nil)
	((NAME))
	((NUMBER_LITERAL)
	 (concat $1))
	((one_or_more_string)))
       (test_list_opt
	(nil)
	((testlist)))
       (testlist
	((comma_sep_test_list comma_opt)
	 (identity $1)))
       (comma_sep_test_list
	((test))
	((comma_sep_test_list COMMA test)
	 (format "%s, %s" $1 $3)))
       (one_or_more_string
	((STRING_LITERAL)
	 (wisent-python-truncate-string $1))
	((one_or_more_string STRING_LITERAL)
	 (wisent-python-truncate-string
	  (concat $1 $2))))
       (lambdef
	((LAMBDA varargslist_opt COLON test)
	 (format "%s %s %s" $1 $2 $3)))
       (varargslist_opt
	(nil)
	((varargslist)))
       (varargslist
	((fpdef_opt_test_list_comma_zom rest_args)
	 (nconc $2 $1))
	((fpdef_opt_test_list comma_opt)))
       (rest_args
	((MULT NAME multmult_name_opt)
	 nil)
	((EXPONENT NAME)
	 nil))
       (multmult_name_opt
	(nil)
	((COMMA EXPONENT NAME)
	 (wisent-token $3 'variable nil nil nil nil)))
       (fpdef_opt_test_list_comma_zom
	(nil)
	((fpdef_opt_test_list_comma_zom fpdef_opt_test COMMA)
	 (nconc $2 $1)))
       (fpdef_opt_test_list
	((fpdef_opt_test))
	((fpdef_opt_test_list COMMA fpdef_opt_test)
	 (nconc $3 $1)))
       (fpdef_opt_test
	((fpdef eq_test_opt)))
       (fpdef
	((NAME)
	 (wisent-token $1 'variable nil nil nil nil)))
       (fplist
	((fpdef_list comma_opt)))
       (fpdef_list
	((fpdef))
	((fpdef_list COMMA fpdef)
	 (identity $1)))
       (eq_test_opt
	(nil)
	((ASSIGN test)
	 nil))
       (comma_opt
	(nil)
	((COMMA)))
       (semicolon_opt
	(nil)
	((SEMICOLON))))
     '(goal function_parameter function_parameters)))
  "Parser automaton.")

(defconst wisent-python-keywords
  ;;DO NOT EDIT! Generated from wisent-python.wy - 2003-01-30 20:10-0800
  (semantic-lex-make-keyword-table
   '(("and" . AND)
     ("assert" . ASSERT)
     ("break" . BREAK)
     ("class" . CLASS)
     ("continue" . CONTINUE)
     ("def" . DEF)
     ("del" . DEL)
     ("elif" . ELIF)
     ("else" . ELSE)
     ("except" . EXCEPT)
     ("exec" . EXEC)
     ("finally" . FINALLY)
     ("for" . FOR)
     ("from" . FROM)
     ("global" . GLOBAL)
     ("if" . IF)
     ("import" . IMPORT)
     ("in" . IN)
     ("is" . IS)
     ("lambda" . LAMBDA)
     ("not" . NOT)
     ("or" . OR)
     ("pass" . PASS)
     ("print" . PRINT)
     ("raise" . RAISE)
     ("return" . RETURN)
     ("try" . TRY)
     ("while" . WHILE)
     ("yield" . YIELD))
   '(("yield" summary "Create a generator function")
     ("while" summary "Start a 'while' loop")
     ("try" summary "Start of statements protected by exception handlers")
     ("return" summary "Return from a function")
     ("raise" summary "Raise an exception")
     ("print" summary "Print each argument to standard output")
     ("pass" summary "Statement that does nothing")
     ("or" summary "Binary logical 'or' operator")
     ("not" summary "Unary boolean negation operator")
     ("is" summary "Binary operator that tests for object equality")
     ("in" summary "Part of 'for' statement ")
     ("import" summary "Load specified modules")
     ("if" summary "Start 'if' conditional statement")
     ("global" summary "Declare one or more symbols as global symbols")
     ("from" summary "Modify behavior of 'import' statement")
     ("for" summary "Start a 'for' loop")
     ("finally" summary "Specify code to be executed after 'try' statements whether or not an exception occured")
     ("exec" summary "Dynamically execute python code")
     ("except" summary "Specify exception handlers along with 'try' keyword")
     ("else" summary "Start the 'else' clause following an 'if' statement")
     ("elif" summary "Shorthand for 'else if' following an 'if' statement")
     ("del" summary "Delete specified objects, i.e., undo what assignment did")
     ("def" summary "Define a new function")
     ("continue" summary "Skip to the next interation of enclosing for or whilte loop")
     ("class" summary "Define a new class")
     ("break" summary "Terminate 'for' or 'while loop")
     ("assert" summary "Raise AssertionError exception if <expr> is false")
     ("and" summary "Logical AND binary operator ... ")))
  "Keywords.")

(defconst wisent-python-tokens
  ;;DO NOT EDIT! Generated from wisent-python.wy - 2003-01-30 20:10-0800
  (wisent-lex-make-token-table
   '(("<no-type>"
      (DEDENT)
      (INDENT))
     ("symbol"
      (NAME))
     ("number"
      (NUMBER_LITERAL))
     ("string"
      (STRING_LITERAL))
     ("charquote"
      (BACKSLASH . "\\"))
     ("punctuation"
      (BACKQUOTE . "`")
      (ASSIGN . "=")
      (COMMA . ",")
      (SEMICOLON . ";")
      (COLON . ":")
      (BAR . "|")
      (TILDE . "~")
      (PERIOD . ".")
      (MINUS . "-")
      (PLUS . "+")
      (MOD . "%")
      (DIV . "/")
      (MULT . "*")
      (AMP . "&")
      (GT . ">")
      (LT . "<")
      (HAT . "^")
      (NE . "!=")
      (LTGT . "<>")
      (HATEQ . "^=")
      (OREQ . "|=")
      (AMPEQ . "&=")
      (MODEQ . "%=")
      (DIVEQ . "/=")
      (MULTEQ . "*=")
      (MINUSEQ . "-=")
      (PLUSEQ . "+=")
      (LE . "<=")
      (GE . ">=")
      (EQ . "==")
      (EXPONENT . "**")
      (GTGT . ">>")
      (LTLT . "<<")
      (DIVDIV . "//")
      (DIVDIVEQ . "//=")
      (EXPEQ . "**=")
      (GTGTEQ . ">>=")
      (LTLTEQ . "<<="))
     ("semantic-list"
      (BRACK_BLOCK . "^\\[")
      (BRACE_BLOCK . "^{")
      (PAREN_BLOCK . "^("))
     ("close-paren"
      (RBRACK . "]")
      (RBRACE . "}")
      (RPAREN . ")"))
     ("open-paren"
      (LBRACK . "[")
      (LBRACE . "{")
      (LPAREN . "("))
     ("newline"
      (NEWLINE)))
   '(("charquote" string t)))
  "Tokens.")

;;;###autoload
(defun wisent-python-default-setup ()
  "Setup buffer for parse."
  ;;DO NOT EDIT! Generated from wisent-python.wy - 2003-01-30 20:10-0800
  (progn
    (semantic-install-function-overrides
     '((parse-stream . wisent-parse-stream)))
    (setq semantic-parser-name "LALR"
	  semantic-toplevel-bovine-table wisent-python-parser-tables
	  semantic-flex-keywords-obarray wisent-python-keywords
	  semantic-lex-types-obarray wisent-python-tokens)
    ;; Collect unmatched syntax lexical tokens
    (semantic-make-local-hook 'wisent-discarding-token-functions)
    (add-hook 'wisent-discarding-token-functions
	      'wisent-collect-unmatched-syntax nil t)
    (setq
     ;; Character used to separation a parent/child relationship
     semantic-type-relation-separator-character '(".")
     semantic-command-separation-character ";"
     ;; Init indentation stack
     wisent-python-lexer-indent-stack '(0)

     semantic-lex-analyzer #'semantic-python-lexer
     semantic-lex-depth	0
     )))

(provide 'wisent-python)

;;; wisent-python.el ends here
