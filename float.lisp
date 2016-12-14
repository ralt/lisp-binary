(defpackage :lisp-binary/float
  (:use :common-lisp :lisp-binary/integer)
  (:export :decode-float-bits :encode-float-bits :read-float :write-float :nanp :infinityp
	   :+inf :-inf :quiet-nan :signalling-nan))

(in-package :lisp-binary/float)

(declaim (optimize (debug 0) (speed 3)))


;; Support actual NaNs and infinities on
;; Lisp implementations that support them.
;; Use keywords to represent them on
;; implementations that don't. Doubles
;; are preferred because some functions
;; need to detect NaN and infinity via
;; the C functions, which only accept
;; doubles (and CFFI doesn't do automatic
;; type promotion like the C compiler does).

;; It would be neat to test for these features
;; instead of relying on implementation names,
;; but unfortunately, some implementations actually
;; crash or hang when trying to evaluate NaNs or
;; infinities, so the tests would crash Lisp
;; instead of failing gracefully.

(eval-when (:compile-toplevel :load-toplevel :execute)
  #+(or sbcl ccl)
  (progn
    (push :float-infinity *features*)
    (push :float-quiet-nan *features*)))

;; Don't make these constants. Floating point arithmetic errors
;; were seen at COMPILE TIME in SBCL.

(defvar +inf
  #+(and float-infinity
	 (not ccl))
  (let ((x 9218868437227405312))
    (cffi:with-foreign-object (ptr :uint64)
      (setf (cffi:mem-ref ptr :uint64) x)
      (cffi:mem-ref ptr :double)))
  #+ccl 1d++0
  #-float-infinity :+inf)

(defvar -inf
  #+(and float-infinity
	 (not ccl))
  (let ((x 18442240474082181120))
    (cffi:with-foreign-object (ptr :uint64)
      (setf (cffi:mem-ref ptr :uint64) x)
      (cffi:mem-ref ptr :double)))
  #+ccl -1d++0
  #-float-infinity :-inf)

;; This is treated as a signalling NaN in CLISP,
;; and thus cannot be evaluated without raising
;; a condition:

(defvar quiet-nan
  #+(and float-quiet-nan
	 (not ccl))
  (let ((x 9221120237041090560))
    (cffi:with-foreign-object (ptr :uint64)
      (setf (cffi:mem-ref ptr :uint64) x)
      (cffi:mem-ref ptr :double)))
  #+ccl 1d+-0
  #-float-quiet-nan
  :quiet-nan)

;; SBCL can't represent a Signalling NaN. Attempting
;; to evaluate this causes it to hang. CCL throws
;; an exception when trying to generate it, and
;; so does CLISP.

(defvar signalling-nan
  #+float-signalling-nan
  (let ((x 9219994337134247936))
    (cffi:with-foreign-object (ptr :uint64)
      (setf (cffi:mem-ref ptr :uint64) x)
      (cffi:mem-ref ptr :double)))
  #-float-signalling-nan :signalling-nan)

(defun float-value (sign significand exponent &optional (base 2))
  "Given the decoded parameters of a floating-point number,
calculate its numerical value."
  (* (expt -1 sign)
     significand
     (expt base exponent)))


(defun calculate-exponent (sign fraction significand)
  (coerce
   (floor
    (/ (log (/ (* fraction (expt -1 sign))
	       significand))
       (log 2)))
   'integer))


(defmacro popbit (place)
  `(prog1 (logand ,place 1)
     (setf ,place (ash ,place -1))))

(defun nanp (decoded-value)
  (or #-float-signalling-nan
      (eq decoded-value :signalling-nan)
      #-float-quiet-nan
      (eq decoded-value :quiet-nan)
      #+(or float-signalling-nan float-quiet-nan)
      (/= (cffi:foreign-funcall #+win32 "_isnan" #-win32 "isnan" :double (coerce decoded-value 'double-float) :int) 0)))

(defun infinityp (decoded-value)
  "Returns two values:
       T if the DECODED-VALUE represents a floating-point infinity
       T if the DECODED-VALUE represents positive infinity, or NIL if it's negative infinity.

Some Lisp implementations support real floating-point infinities, but the ANSI standard does
not require it, and some Lisp implementations don't bother to support them. On those implementations,
infinities are represented by the keywords :+INF and :-INF. To detect positive/negative infinity portably,
use this function."

  #-float-infinity
  (case decoded-value
    (:+inf (values t t))
    (:-inf (values t nil))
    (otherwise nil))
  #+float-infinity
  (and (not (nanp decoded-value))
       (values #-win32(/= (cffi:foreign-funcall "isinf" :double (coerce decoded-value 'double-float) :int)
			  0)
	       #+win32 (= (cffi:foreign-funcall "_finite" :double (coerce decoded-value 'double-float) :int))
	       (> decoded-value 0))))


(defun float-coerce (value result-type)
  "Coerce the VALUE to the RESULT-TYPE, taking into account the fact that values
generated by this library are not always actually numbers. So on Lisp systems that
don't support infinity, (FLOAT-COERCE :+INF 'DOUBLE-FLOAT) will actually leave it
alone.

Also takes into account the fact that even on Lisps that do support infinities and NaNs,
you can't coerce them to non-floating-point numbers, so it passes infinities and NaNs
through untouched if the RESULT-TYPE isn't floating-point.

There should never be an error as a result of trying to decode a floating-point bit pattern
to a number."
  #+(and float-infinity float-quiet-nan float-signalling-nan)
  (when (member result-type '(float single-float double-float))
    (return-from float-coerce
      (coerce value result-type)))
  (cond ((infinityp value)
	 #-float-infinity
	 value
	 #+float-infinity
	 (if (member result-type '(float single-float double-float))
	     (coerce value result-type)
	     value))
	((nanp value)
	 value)
	(t (coerce value result-type))))

(eval-when (:compile-toplevel :load-toplevel :execute)
  ;; Syntax:
  ;; (:name significand-bits-with-implicit-bit exponent-bits exponent-bias)
  (defvar *format-table*
    '((:half 11 5 15)
      (:single 24 8 127)
      (:double 53 11 1023)
      (:quadruple 113 15 16383)
      (:octuple 237 19 262143)))

  (defun get-format (format)
    (or (assoc format *format-table*)
	(restart-case
	    (error "Unknown floating-point format ~a" format)
	  (use-value (new-format)
	    :report "Enter a different format to use"
	    :interactive (lambda ()
			   (format t "Supported formats:~%~%")
			   (loop for (format . fuck) in *format-table*
			      do (format t "    ~s~%" format))
			   (terpri)
			   (format t "Format to use (unevaluated): ")
			   (force-output)
			   (list (read)))
	    (get-format new-format)))))

  (defun format-size (format)
    "Returns the size in bytes of a given floating-point format."
    (destructuring-bind (format some-bits more-bits who-cares)
	(get-format format)
      (declare (ignore format who-cares))
    
      (/ (+ some-bits more-bits) 8))))


(eval-when (:compile-toplevel :load-toplevel :execute)
  (defmacro decode-float-bits (integer &key (format :single)
					 (result-type ''float))
    "Decodes the bits from an IEEE floating point number. Supported formats are
listed in the variable LISP-BINARY/FLOAT::*FORMAT-TABLE*.

If the FORMAT is either :SINGLE or :DOUBLE, then the decoding is
done by storing the bits in memory and having the CPU reinterpret that buffer
as a float. Otherwise, arithmetic methods are used to arrive at the correct value.

To prevent precision loss if you are decoding a larger type such as :QUADRUPLE
or :OCTUPLE precision, use 'RATIONAL for the RESULT-TYPE to avoid a conversion to
a smaller 32- or 64-bit float.

"
    ;; This declaration is REQUIRED under CCL because its optimizer
    ;; does something crazy that results in the DECODE-FLOAT-BITS/ARITHMETIC
    ;; expansion always being chosen.
    #+ccl (declare (optimize (speed 0) (debug 3)))
    (cond ((and (member format '(:single :double))
		(member result-type '('float 'single-float 'double-float) :test #'equal))
	   `(float-coerce (decode-float-bits/cffi ,integer :format ,format)
		    ,result-type))
	  ((keywordp format)
	   (destructuring-bind (format significand-bits exponent-bits exponent-bias) (get-format format)
	     (declare (ignore format))
	     (let ((temp-result (gensym)))
	       `(let ((,temp-result (decode-float-bits/arithmetic ,integer ,significand-bits ,exponent-bits ,exponent-bias)))
		  (if (or (nanp ,temp-result)
			  (infinityp ,temp-result))
		      ,temp-result
		      (float-coerce ,temp-result ,result-type))))))
	  (t (let ((runtime-format (gensym))
		   (significand-bits (gensym))
		   (exponent-bits (gensym))
		   (exponent-bias (gensym))
		   (temp-result (gensym)))
	       `(destructuring-bind (,runtime-format ,significand-bits ,exponent-bits ,exponent-bias) (get-format ,format)
		  (declare (ignore ,runtime-format))
		  (let ((,temp-result (decode-float-bits/arithmetic ,integer ,significand-bits ,exponent-bits ,exponent-bias)))
		    (if (or (nanp ,temp-result)
			    (infinityp ,temp-result))
			,temp-result
			(float-coerce ,temp-result ,result-type))))))))

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defun get-exponent (integer significand-bits exponent-bits exponent-bias)
    (- (logand (- (ash 1 exponent-bits) 1)
	       (ash integer (- (- significand-bits 1))))
       exponent-bias))

  (defun get-significand (integer significand-bits)
    "Given an INTEGER that represents the bit-pattern of a floating point number,
extract the bits that represent the significand. SIGNIFICAND-BITS specifies the
number of bits in the significand. Does not add the implicit bit."
    (logand (- (ash 1 significand-bits) 1)
	    integer))

  (defun exponent-all-ones-p (integer significand-bits exponent-bits)
    (= (get-exponent integer significand-bits exponent-bits 0)
       (1- (ash 1 exponent-bits))))

  (defun %infinityp (integer significand-bits exponent-bits)
    (and (exponent-all-ones-p integer significand-bits exponent-bits)
	 (= (get-significand integer (1- significand-bits)) 0)))

  (defun %qnanp (integer significand-bits exponent-bits)
    (let ((significand (get-significand integer (1- significand-bits))))
      (and (exponent-all-ones-p integer significand-bits exponent-bits)
	   (= significand (ash 1 (- significand-bits 2))))))
  
  (defun %snanp (integer significand-bits exponent-bits)
    (let ((significand (get-significand integer (1- significand-bits))))
      (and (exponent-all-ones-p integer significand-bits exponent-bits)
	   (= significand (ash 1 (- significand-bits 3))))))
  
  (defun decode-significand (significand significand-bits raw-exponent)
    (unless (= 0 raw-exponent)
      ;; If the exponent is all 0s, that means we're decoding a "denormalized"
      ;; number with no implicit leading 1 bit.
      ;;
      (setf significand (logior (ash 1 (1- significand-bits)) significand)))
    (loop for i from (1- significand-bits) downto 0
       for bit = (popbit significand)
       sum (* bit (expt 2 (- i)))))

  (defun exponent-zero-p (integer significand-bits exponent-bits)
    (zerop (get-exponent integer significand-bits exponent-bits 0)))

  (defun decode-float-bits/arithmetic (integer significand-bits exponent-bits exponent-bias)
    "Decodes IEEE floating-point from an integer bit-pattern."
    (declare (type integer integer significand-bits exponent-bits))
    (let ((sign (ash integer (- (+ (- significand-bits 1) exponent-bits))))
	  (exponent (get-exponent integer significand-bits exponent-bits
				  exponent-bias))
	  (significand (get-significand integer (1- significand-bits))))
      (cond ((%infinityp integer significand-bits exponent-bits)
	     (if (= sign 0)
		 +inf
		 -inf))
	    ((%qnanp integer significand-bits exponent-bits)
	     quiet-nan)
	    ((%snanp integer significand-bits exponent-bits)
	     signalling-nan)
	    ((exponent-zero-p integer significand-bits exponent-bits)
	     ;; Denormal decoding
	     (float-value sign (decode-significand significand significand-bits 0) (- (1- exponent-bias))))
	    (t
	     (float-value sign (decode-significand significand significand-bits
						   (get-exponent integer significand-bits exponent-bits 0)) exponent))))))


(defun make-smallest-denormal (format result-type)
    "FIXME: The actual smallest denormal for :SINGLE should be 2^-149, not 2^-127. I have no idea how to derive that value,
so I don't know what it should be for other types, nor what the largest denormal value should be."
    (decode-float-bits 1 :format format :result-type result-type))
  
  (defun make-largest-denormal (format result-type)
    (let ((significand-bits (second (get-format format))))
      (decode-float-bits (1- (ash 1 (1- significand-bits))) :format format :result-type result-type))))

(defparameter *denormals*
  (loop for (format . rest) in *format-table*
     collect (list format (make-smallest-denormal format 'rational)
		   (make-largest-denormal format 'rational))))

(defun denormalp (number format)
  (destructuring-bind (smallest largest) (cdr (assoc format *denormals*))
    ;; FIXME: CCL can't compare infinity to rational numbers!
    (< smallest (abs number) largest)))

(defun denormalp/arithmetic (number significand-bits exponent-bits exponent-bias)
  (denormalp number
   (loop for (format signif-bits exp-bits exp-bias) in *format-table*
      when (equal (list signif-bits exp-bits exp-bias)
		  (list significand-bits exponent-bits exponent-bias))
      return format)))

(defun encode-significand (significand significand-bits)
  ;; The ASH is to remove an anomalous extra bit that ends up in
  ;; the output somehow.
    (ash (loop for b from 0 to significand-bits
	    for power-of-two = (expt 2 (- b))
	    if (>= significand power-of-two)
	       do (decf significand power-of-two)
	       and sum (ash 1 (- significand-bits b)))
	 -1))

(defun %make-infinity (positivep significand-bits exponent-bits)
  (logior (ash (if positivep 0 1)
	       (+ (1- significand-bits) exponent-bits))
	  (ash (1- (ash 1 exponent-bits))
	       (1- significand-bits))))

(defun %make-quiet-nan (significand-bits exponent-bits)
  (logior (ash (1- (ash 1 exponent-bits))
		 (1- significand-bits))
	    (ash 1 (- significand-bits 2))))

(defun %make-signalling-nan (significand-bits exponent-bits)
  (logior (ash (1- (ash 1 exponent-bits))
	       (1- significand-bits))
	  (ash 1 (- significand-bits 3))))

(defun calculate-significand (fraction significand-bits)
  "Given a FRACTION and number of SIGNIFICAND-BITS, calculates the
integer significand. The significand returned includes the implicit
bit, which must be removed in the final floating-point encoding."
  (multiple-value-bind (int-part frac-part)
      (floor fraction)
    (let ((bits-consumed (loop for n from 0 unless
			      (< (ash 1 n) int-part)
			    return n)))
      (logior
       (ash int-part (- significand-bits bits-consumed))
	(loop for bit downfrom (- significand-bits (incf bits-consumed))
	   repeat (1+ (- significand-bits bits-consumed))
	   sum (multiple-value-bind (int frac)
		   (floor (* frac-part 2))
		 (setf frac-part frac)
		 (ash int bit)))))))

(defun encode-float-bits/arithmetic (fraction significand-bits exponent-bits exponent-bias)
  "Calculate the bits of a floating-point number using plain arithmetic, given the FRACTION
and the format information SIGNIFICAND-BITS, EXPONENT-BITS, and EXPONENT-BIAS. The returned
value is an integer."
  (case fraction
    #-float-infinity (:+inf (%make-infinity t significand-bits exponent-bits))
    #-float-infinity (:-inf (%make-infinity nil significand-bits exponent-bits))
    #-float-quiet-nan (:quiet-nan (%make-quiet-nan significand-bits exponent-bits))
    #-float-signalling-nan (:signalling-nan (%make-signalling-nan significand-bits exponent-bits))
    (otherwise
     
     #+float-infinity
     (when (infinityp fraction)
       (return-from encode-float-bits/arithmetic
	 (%make-infinity (> fraction 0.0d0) significand-bits exponent-bits)))

     ;; The question of how to tell a quiet NaN from
     ;; a signalling NaN cannot be answered until I
     ;; see a Lisp implementation that can evaluate
     ;; signalling NaNs. In currently supported implementations,
     ;; signalling NaN will be represented by the keyword
     ;; :SIGNALLING-NAN, and quiet NaNs might be, too.
     #+(or float-signalling-nan float-quiet-nan)
     (when (nanp fraction)
       (return-from encode-float-bits/arithmetic
	 (%make-quiet-nan significand-bits exponent-bits)))
     
     (let* ((denormalp (denormalp/arithmetic fraction significand-bits exponent-bits exponent-bias))
	    (sign (if (> fraction 0)
		      0 1))
	    (significand (if denormalp
			     (calculate-significand (/ fraction (expt 2 (- (1- exponent-bias)))) (1- significand-bits))
			     (calculate-significand fraction significand-bits)))
	    (exponent (if denormalp
			  0
			  (calculate-exponent sign fraction (decode-significand significand significand-bits #b11111)))))
       (logior (ash sign (+ (1- significand-bits) exponent-bits))
	       (logand
		(1- (ash 1 (1- significand-bits)))
		significand)
	       (ash 
		(if denormalp 0
		    (+ exponent exponent-bias))
		(1- significand-bits)))))))

(defun encode-float-bits/cffi (fraction &key (format :single))
  (declare (type float fraction))
  (multiple-value-bind (c-float-type c-int-type lisp-type)
      (ecase format
	(:single (values :float :uint32 'single-float))
	(:double (values :double :uint64 'double-float)))
    (cffi:with-foreign-object (x c-float-type)
      (setf (cffi:mem-ref x c-float-type) (coerce fraction lisp-type))      
      (cffi:mem-ref x c-int-type))))

(defun encode-float-bits/runtime-format (fraction format)
  (if (member format '(:single :double))
      (encode-float-bits/cffi (coerce fraction 'float) :format format)
      (destructuring-bind (format significand-bits exponent-bits exponent-bias)
	  (get-format format)
	(declare (ignore format))
	(encode-float-bits/arithmetic fraction significand-bits exponent-bits exponent-bias))))

(defmacro encode-float-bits/arithmetic-macro (fraction format)
  (cond	((keywordp format)
	 (destructuring-bind (format significand-bits exponent-bits exponent-bias) (get-format format)
	   (declare (ignore format))
	   `(encode-float-bits/arithmetic ,fraction ,significand-bits ,exponent-bits ,exponent-bias)))
	(t
	 `(encode-float-bits/runtime-format ,fraction ,format))))
  
(defmacro encode-float-bits (fraction &key (format :single))
  (cond ((member format '(:single :double))
	 (alexandria:with-gensyms (fraction-value)
	   #-(and float-infinity float-quiet-nan float-signalling-nan)
	   `(let ((,fraction-value ,fraction))
	      (if (symbolp ,fraction-value)
		  (encode-float-bits/arithmetic-macro ,fraction-value ,format)
		  (encode-float-bits/cffi (coerce ,fraction-value 'float) :format ,format)))
	   #+(and float-infinity float-quiet-nan float-signalling-nan)
	   `(encode-float-bits/cffi (coerce ,fraction-value 'float) :format ,format)))
	(t `(encode-float-bits/arithmetic-macro ,fraction ,format))))


(defun decode-float-bits/cffi (integer &key (format :single))
  "Decodes the bits from a read-in floating-point number using the hardware. Assumes
that only :SINGLE and :DOUBLE work."
  (let (#-(and float-quiet-nan
	    float-signalling-nan
	    float-infinity)
	  (format-info (get-format format))
	(c-float-type (ecase format
			(:single :float)
			(:double :double)))
	(c-int-type (ecase format
		      (:single :uint32)
		      (:double :uint64))))
    #-float-quiet-nan
    (when (%qnanp integer (second format-info) (third format-info))
      (return-from decode-float-bits/cffi quiet-nan))
    #-float-signalling-nan
    (when (%snanp integer (second format-info) (third format-info))
      (return-from decode-float-bits/cffi signalling-nan))
    #-float-infinity
    (when (%infinityp integer (second format-info) (third format-info))
      (return-from decode-float-bits/cffi
	(decode-float-bits/arithmetic integer (second format-info) (third format-info) (fourth format-info))))
  
    (cffi:with-foreign-object (x c-int-type)
      (setf (cffi:mem-ref x c-int-type) integer)
      (cffi:mem-ref x c-float-type))))
	    
  
(defun make-infinity (positivep format)
  "Creates a floating-point infinity. Returns the integer bit pattern."
  (destructuring-bind (format-name significand-bits exponent-bits exponent-bias) (get-format format)
    (declare (ignore exponent-bias format-name))
     (%make-infinity positivep significand-bits exponent-bits)))

(defun make-quiet-nan (format)
  (destructuring-bind (format-name significand-bits exponent-bits exponent-bias) (get-format format)
    (declare (ignore format-name exponent-bias))
     (%make-quiet-nan significand-bits exponent-bits)))

(defun make-signalling-nan (format)
  (destructuring-bind (format-name significand-bits exponent-bits exponent-bias) (get-format format)
    (declare (ignore format-name exponent-bias))
    (%make-signalling-nan significand-bits exponent-bits)))


(defun %read-float (format stream result-type byte-order)
  (let ((size (format-size format)))
    (values
     (decode-float-bits (read-integer size stream :byte-order byte-order)
			:result-type result-type :format format)
     size)))

(defmacro read-float (format &key (stream *standard-input*) (result-type ''float) (byte-order :little-endian))
  (if (keywordp format) ;; Is the format known at compile time?
      (let ((size (format-size format)))
	`(values (decode-float-bits (read-integer ,size ,stream :byte-order ,byte-order)
				    :format ,format :result-type ,result-type)
		 ,size))
      `(%read-float ,format ,stream ,result-type ,byte-order)))

(defun %write-float (format fraction stream byte-order)
  (let ((size (format-size format)))
    (write-integer (encode-float-bits fraction :format format)
				size stream :byte-order byte-order)))

(defmacro write-float (format fraction &key (stream *standard-input*) (byte-order :little-endian))
  (if (keywordp format)
      (let ((size (format-size format)))
	`(write-integer (encode-float-bits ,fraction :format ,format)
					     ,size ,stream :byte-order ,byte-order))
      `(%write-float ,format ,fraction ,stream ,byte-order)))

